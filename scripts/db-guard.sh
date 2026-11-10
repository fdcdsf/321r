#!/usr/bin/env bash
# db-guard.sh — переводчик Swarm → PG/Mongo + страж-фенсер (PLAN v14, фаза 4, шаг 6).
# Запуск: systemd-timer каждые 5 с на КАЖДОЙ ноде; логи — journalctl -t db-guard
# (в штатном режиме молчит: пишем только назначения, переключения прокси и фенс).
#
# Контракт (единый для обоих движков):
#   1. healthcheck — TCP до текущего первичного из метки db-primary-<app>;
#   2. голоса менеджеров — своя нода пишет метку vote.<app>.<алиас>=<0|1>-<epoch>,
#      свежесть 45 с; «мёртвых» ≥ кворума (⌊M/2⌋+1) → первичный объявлен мёртвым;
#   3. кандидат — только следующий по цепи S(X) из реестра (гонки двух промоушенов нет);
#   4. назначение: PG — pg_ctl promote (+шаг назад вернувшегося старого первичного),
#      Mongo — rs.conf: priority 1 назначенному, 0 остальным (force-reconfig без первичного);
#   5. claim метки db-primary-<app>; прокси PG переключает апстрим на текущий первичный
#      (haproxy.cfg правится БЕЗ замены inode: ro-монтирование контейнера держит копию);
#   6. фенс (вариант Б): нет кворума Swarm >60 с → DROP в DOCKER-USER:
#      -s/-d 10.66.0.0/24 — рвёт mesh (чужие не достучатся, свои не убегут);
#      -s 172.16.0.0/12 — рвёт и ЛОКАЛЬНЫЙ путь приложение→haproxy→первичный на самой
#      ноде (иначе изолированный первичный продолжал бы принимать записи — сплит-брейн);
#      кворум вернулся → правила снимаются, стендбай догоняет по WAL.
# Без кворума решений не принимаем вообще (CP): тик ограничивается только фенсом.
set -euo pipefail
umask 077

STATE_DIR=/var/lib/db-guard
QUORUM_FILE="$STATE_DIR/quorum.ok"
FRESH=45          # свежесть голоса, с
FENCE_AFTER=60    # столько без кворума — фенс, с
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0        # предыдущий тик ещё работает — пропускаем

SSHOPTS=(-p 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=3)
log() { logger -t db-guard -- "$*"; }
now=$(date +%s)

# ---------- nodes.map ----------
map_ip()    { awk -v a="$1" '$1==a{print $2}' /etc/db/nodes.map; }
map_swarm() { awk -v a="$1" '$1==a{print $3}' /etc/db/nodes.map; }
mapfile -t ALL_NODES < <(awk '{print $1}' /etc/db/nodes.map)
ME_ALIAS="$(awk -v s="$(hostname)" '$3==s{print $1}' /etc/db/nodes.map)"
[ -n "$ME_ALIAS" ] || { log "hostname $(hostname) не найден в nodes.map — тик пропущен"; exit 1; }
ME_IP="$(map_ip "$ME_ALIAS")"

IS_MANAGER=0
if docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | grep -q true; then
  IS_MANAGER=1
fi

# ---------- кворум Swarm + фенс ----------
swarm_ok() {
  if [ "$IS_MANAGER" = 1 ]; then
    timeout 5 docker node ls >/dev/null 2>&1
  else
    # worker: тот же вызов ssh'ем на менеджера (адреса — из RemoteManagers)
    local mgr ip
    mgr="$(docker info --format '{{range .Swarm.RemoteManagers}}{{.Addr}} {{end}}' 2>/dev/null | awk '{print $1}')"
    [ -n "$mgr" ] || return 1
    ip="${mgr%:*}"
    timeout 8 ssh "${SSHOPTS[@]}" "root@$ip" 'docker node ls' >/dev/null 2>&1
  fi
}

fence_on() {
  local rc=0
  iptables -C DOCKER-USER -s 10.66.0.0/24 -j DROP 2>/dev/null || iptables -I DOCKER-USER 1 -s 10.66.0.0/24 -j DROP || rc=1
  iptables -C DOCKER-USER -d 10.66.0.0/24 -j DROP 2>/dev/null || iptables -I DOCKER-USER 1 -d 10.66.0.0/24 -j DROP || rc=1
  iptables -C DOCKER-USER -s 172.16.0.0/12 -j DROP 2>/dev/null || iptables -I DOCKER-USER 1 -s 172.16.0.0/12 -j DROP || rc=1
  if [ "$rc" = 0 ]; then
    log "ФЕНС: нет кворума Swarm дольше $FENCE_AFTER с — контейнеры изолированы (DOCKER-USER DROP: mesh и локальный путь)"
  else
    log "ФЕНС: ошибка вставки правила iptables"
  fi
  return "$rc"
}
fence_off() {
  if iptables -C DOCKER-USER -s 10.66.0.0/24 -j DROP 2>/dev/null; then
    iptables -D DOCKER-USER -s 10.66.0.0/24 -j DROP || true
  fi
  if iptables -C DOCKER-USER -d 10.66.0.0/24 -j DROP 2>/dev/null; then
    iptables -D DOCKER-USER -d 10.66.0.0/24 -j DROP || true
  fi
  if iptables -C DOCKER-USER -s 172.16.0.0/12 -j DROP 2>/dev/null; then
    iptables -D DOCKER-USER -s 172.16.0.0/12 -j DROP || true
  fi
  log "ФЕНС снят: кворум Swarm восстановлен — стендбаи догоняют по WAL"
}

QUORUM_OK=0
if swarm_ok; then
  QUORUM_OK=1
  echo "$now" > "$QUORUM_FILE"
  if [ -f "$STATE_DIR/fenced" ]; then
    fence_off || true
    rm -f "$STATE_DIR/fenced"
  fi
else
  [ -f "$QUORUM_FILE" ] || echo "$now" > "$QUORUM_FILE"   # отсчёт с первой потери
  last="$(cat "$QUORUM_FILE")"
  if [ ! -f "$STATE_DIR/fenced" ] && [ $((now - last)) -gt $FENCE_AFTER ]; then
    fence_on || true
    touch "$STATE_DIR/fenced"
  fi
fi
# без кворума решений не принимаем (CP): дальше — только при живом кворуме
[ "$QUORUM_OK" = 1 ] || exit 0

# ---------- реестр и простые проверки ----------
val() { sed -n "s/^$1: *//p" "$REG" | head -1 | sed 's/#.*$//; s/[[:space:]]*$//'; }
tcp_ok() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

cast_vote() {  # $1=app $2=0|1 — голос от МЕНЕДЖЕРА о живости первичного
  [ "$IS_MANAGER" = 1 ] || return 0
  docker node update --label-add "vote.$1.$ME_ALIAS=$2-$(date +%s)" "$(map_swarm "$ME_ALIAS")" >/dev/null
}

count_votes() { # $1=app → DEAD_DECLARED=0|1; голоса старше 45 с не считаются
  local app="$1" n fmt mgrval v ts M=0 dead=0 quorum
  DEAD_DECLARED=0
  for n in "${ALL_NODES[@]}"; do
    fmt="{{if .ManagerStatus}}1{{end}};{{index .Spec.Labels \"vote.$app.$n\"}}"
    mgrval="$(docker node inspect "$(map_swarm "$n")" --format "$fmt" 2>/dev/null || true)"
    [ "${mgrval%%;*}" = 1 ] || continue        # не менеджер — не голосует
    M=$((M + 1))
    v="${mgrval#*;}"
    case "$v" in 0-*|1-*) ;; *) continue ;; esac
    ts="${v##*-}"
    [ $((now - ts)) -le $FRESH ] || continue   # устаревший голос не считаем
    [ "${v%%-*}" = 0 ] && dead=$((dead + 1))
  done
  quorum=$((M / 2 + 1))
  [ "$dead" -ge "$quorum" ] && DEAD_DECLARED=1
  return 0
}

next_of() { # следующий по цепи S(X) после $1; пусто — если $1 не в S
  local idx=-1 i=0 n
  for n in "${S[@]}"; do
    [ "$n" = "$1" ] && idx=$i
    i=$((i + 1))
  done
  [ "$idx" -ge 0 ] || { echo ""; return 0; }
  echo "${S[$(((idx + 1) % ${#S[@]}))]}"
  return 0
}

watch_instance() { # $1=app $2=состояние (пусто = мой инстанс не отвечает) $3=контейнер.
  # Один сигнал при падении, один при возврате — без спама на каждом тике.
  # Зачем: ручной docker stop / сбой оставляли инстанс лежать МОЛЧА (все ветки тика
  # про него молчали) — инцидент 2026-11-10: контейнер на a лежал 2 часа без единой записи.
  local app="$1" st="$2" ctr="$3" f="$STATE_DIR/down.$1"
  if [ -z "$st" ]; then
    if [ ! -f "$f" ]; then
      touch "$f"
      log "$app: мой инстанс НЕ отвечает — контейнер $ctr лежит? нужен 'docker start $ctr'"
    fi
  elif [ -f "$f" ]; then
    rm -f "$f"
    log "$app: мой инстанс снова отвечает ($st)"
  fi
  return 0
}

claim() { # $1=app $2=alias — перехват метки первичного (метка живёт ТОЛЬКО на узле первичного,
  # иначе после failover чтение по порядку S найдёт устаревшую копию на старом узле).
  # docker node update — read-modify-write всего Spec: соседний тик (голос vote...) может
  # прочитать Spec ДО нашей правки и записать ПОСЛЕ — тогда метка «возвращается» (рокировка
  # на дрели как раз так и ловилась). Поэтому: inspect-first (узел без метки не трогаем),
  # ошибки не глушим, после правки ПРОВЕРКА по всем нодам и до 3 попыток; расхождение —
  # громкий лог, следующий тик повторит.
  local app="$1" new="$2" n d out i ok
  local fmt="{{index .Spec.Labels \"db-primary-$app\"}}"
  for i in 1 2 3; do
    for n in "${ALL_NODES[@]}"; do
      [ "$n" = "$new" ] && continue
      d="$(docker node inspect "$(map_swarm "$n")" --format "$fmt" 2>/dev/null)" || d="__NOINSPECT__"
      case "$d" in ""|"<no value>") continue ;; esac     # метки нет — нечего снимать
      # флаг РЕАЛЬНЫЙ: docker node update имеет --label-rm (а не --label-remove — rc=125;
      # именно этим в дрели снятие метки молча не работало и происходил флэп)
      out="$(docker node update --label-rm "db-primary-$app" "$(map_swarm "$n")" 2>&1)" || \
        log "$app: label-rm на $n не прошёл (попытка $i): ${out:-пусто}"
    done
    out="$(docker node update --label-add "db-primary-$app=$new" "$(map_swarm "$new")" 2>&1)" || \
      log "$app: label-add на $new не прошёл (попытка $i): ${out:-пусто}"
    sleep 1
    # верификация: метка есть ТОЛЬКО у $new и только с его значением
    ok=1
    for n in "${ALL_NODES[@]}"; do
      d="$(docker node inspect "$(map_swarm "$n")" --format "$fmt" 2>/dev/null)" || d="__NOINSPECT__"
      case "$d" in
        ""|"<no value>") if [ "$n" = "$new" ]; then ok=0; fi ;;
        *) if [ "$n" != "$new" ] || [ "$d" != "$new" ]; then ok=0; fi ;;
      esac
    done
    if [ "$ok" = 1 ]; then return 0; fi
  done
  log "$app: claim метки не сошёлся за 3 попытки (нужен $new) — повторим в следующем тике"
  return 1
}

# ---------- PostgreSQL ----------
pg_recovery() { # t|f; пусто — контейнер не отвечает
  docker exec -u postgres "pg-$1" psql -U postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || true
}

promote_pg() { # $1=app
  local app="$1" i
  docker exec -u postgres "pg-$app" pg_ctl promote >/dev/null 2>&1 || return 1
  for i in $(seq 1 15); do
    if [ "$(pg_recovery "$app")" = f ]; then
      # закрепляем переход: без standby.signal рестарт останется первичным
      rm -f "/var/lib/dbdata/pg-$app/standby.signal"
      return 0
    fi
    sleep 1
  done
  return 1
}

pg_become_standby() { # $1=app $2=ip первичного: переписать conninfo + standby.signal + рестарт
  local app="$1" dip="$2" dir="/var/lib/dbdata/pg-$1" i
  [ -n "$dip" ] || return 1
  [ -d "$dir" ] || return 1
  [ -f "/etc/db/secrets/$app.env" ] || { log "$app: нет файла секретов"; return 1; }
  . "/etc/db/secrets/$app.env"
  echo "primary_conninfo = 'host=$dip port=$PORT user=replicator password=${REPL_PASSWORD}'" >> "$dir/postgresql.auto.conf"
  rm -f "$dir/promote.signal"    # иначе при рестарте сигнал промоушена перебьёт standby
  touch "$dir/standby.signal"
  docker restart "pg-$app" >/dev/null
  for i in $(seq 1 15); do
    [ "$(pg_recovery "$app")" = t ] && return 0
    sleep 1
  done
  return 1
}

pg_wal_target_ok() { # стендбай УЖЕ настроен на $2? Сравниваем КОНФИГ (SHOW primary_conninfo),
  # а не состояние приёмника (pg_stat_wal_receiver): при мёртвом приёмнике (таймлайн 5≠1 —
  # нода c в дрели) receiver-строка пуста, старая проверка врала «не перевешан» и зацикливала
  # рестарт каждые ~12 с. Конфиг верен → просто ждём, пока приёмник оживёт сам (или пересборка).
  docker exec -u postgres "pg-$1" psql -U postgres -tAc \
    'SHOW primary_conninfo' 2>/dev/null | grep -q "host=$2 port="
}

pg_proxy_repoint() { # $1=app $2=ip апстрима — на любой ноде, где есть блок приложения
  local app="$1" dip="$2" f=/opt/db/proxy/haproxy.cfg cur
  [ -f "$f" ] || return 0
  grep -q "# BEGIN $app" "$f" || return 0
  cur="$(sed -n "s/^ *server primary \([0-9.]*\):${PORT} .*/\1/p" "$f" | head -1)"
  [ -n "$cur" ] && [ "$cur" = "$dip" ] && return 0
  # правим БЕЗ замены inode: ro-монтирование контейнера держит старую копию
  sed "s|server primary [0-9.]*:${PORT}|server primary ${dip}:${PORT}|" "$f" > "$f.tmp"
  cat "$f.tmp" > "$f"
  rm -f "$f.tmp"
  chmod 644 "$f"
  docker exec db-proxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1 || {
    log "$app: конфиг прокси не прошёл haproxy -c — переключение пропущено"
    return 1
  }
  docker kill -s USR1 db-proxy >/dev/null 2>&1 || true
  sleep 1
  if ! docker inspect -f '{{.State.Running}}' db-proxy 2>/dev/null | grep -q true; then
    docker compose -f /opt/db/proxy/docker-compose.yml up -d >/dev/null 2>&1 || true
    log "$app: прокси упал после переключения — поднят заново"
  fi
  log "$app: апстрим прокси → $dip"
  return 0
}

# ---------- MongoDB ----------
mongosh_eval() { # $1=app $2=js (всегда статус 0: пусто = движок не отвечает)
  docker exec "mongod-$1" mongosh --quiet --eval "$2" 2>/dev/null || true
}

mongo_state() { # myState (1/2/3), -1 = RS не поднят, "" = контейнер не отвечает
  mongosh_eval "$1" 'try { print(rs.status().myState) } catch (e) { print(-1) }'
}

mongo_primaries() { # сколько участников PRIMARY; ошибка → -1
  mongosh_eval "$1" 'try { print(rs.status().members.filter(function (m) { return m.stateStr === "PRIMARY" }).length) } catch (e) { print(-1) }'
}

mongo_reconfig_pri() { # $1=app $2=host с priority 1; $3=1 → force (когда первичного нет)
  local opts='{}' js
  [ "$3" = 1 ] && opts='{force: true}'
  js="var c = rs.conf(); var p1 = '$2'; var ch = false;
c.members.forEach(function (m) { if (m.arbiterOnly) return;
  var w = (m.host === p1) ? 1 : 0;
  var cur = (m.priority === undefined ? 1 : m.priority);
  if (cur !== w) { m.priority = w; ch = true; } });
if (ch) { try { rs.reconfig(c, $opts); print('reconfig ok') } catch (e) { print('reconfig err: ' + e) } } else { print('pri ok') }"
  mongosh_eval "$1" "$js"
}

mongo_stepdown() {
  mongosh_eval "$1" 'try { rs.stepDown(60); print("stepdown ok") } catch (e) { print("stepdown err: " + e) }'
}

# ======================================================================
for REG in /etc/db/apps.d/*.yaml; do
  [ -f "$REG" ] || continue
  APP="$(val name)"
  ENGINE="$(val engine | tr -d ' ')"
  CLASS="$(val class | tr -d ' ')"
  PORT="$(val port | tr -d ' ')"
  REG_PRIMARY="$(val primary | tr -d ' ')"
  read -r -a S < <(val placement | tr -d '[] ' | tr ',' ' ') || true
  CLASS="${CLASS:-cluster}"
  if [ -z "$APP" ] || [ -z "$ENGINE" ] || [ -z "$PORT" ] || [ "${#S[@]}" -lt 1 ]; then
    log "$REG: неполный реестр — пропуск"
    continue
  fi
  [ "$CLASS" = cluster ] || continue          # local: назначать некого
  case "$ENGINE" in pg|mongo) ;; *) continue ;; esac

  # текущий первичный — из метки на нодах S (фолбэк — стартовый из реестра)
  designated=""; inS=0
  for n in "${S[@]}"; do
    [ "$n" = "$ME_ALIAS" ] && inS=1
    if [ -z "$designated" ]; then
      d="$(docker node inspect "$(map_swarm "$n")" --format "{{index .Spec.Labels \"db-primary-$APP\"}}" 2>/dev/null || true)"
      case "$d" in ""|"<no value>") ;; *) designated="$d" ;; esac
    fi
  done
  [ -n "$designated" ] || designated="$REG_PRIMARY"
  D_IP="$(map_ip "$designated")"

  # голос: первичный жив с МОЕЙ точки зрения (TCP до его порта)
  alive=0
  if [ -n "$D_IP" ] && tcp_ok "$D_IP" "$PORT"; then alive=1; fi
  cast_vote "$APP" "$alive" || log "$APP: голос не записан"
  count_votes "$APP"

  if [ "$ENGINE" = pg ]; then
    rec="$(pg_recovery "$APP")"
    [ -d "/var/lib/dbdata/pg-$APP" ] && watch_instance "$APP" "$rec" "pg-$APP"

    # --- назначение: объявлен мёртвым, я — следующий по цепи ---
    if [ "$DEAD_DECLARED" = 1 ]; then
      nxt="$(next_of "$designated")"
      if [ -n "$nxt" ] && [ "$nxt" = "$ME_ALIAS" ] && [ "$inS" = 1 ]; then
        if [ "$rec" = t ]; then
          if promote_pg "$APP"; then
            rec="f"    # я теперь первичный: ниже не должен сам себя «понизить»
            if claim "$APP" "$ME_ALIAS"; then
              log "$APP: ПРОМОУШЕН — $ME_ALIAS стал первичным (голосов «мёртв» ≥ кворума)"
              designated="$ME_ALIAS"; D_IP="$ME_IP"   # прокси и остальные ветки тика — уже про меня
            else
              log "$APP: ПРОМОУШЕН — $ME_ALIAS стал первичным, но claim метки не прошёл — повторим"
            fi
          else
            log "$APP: promote не удался — повторим в следующем тике"
          fi
        elif [ "$rec" = f ]; then
          # я уже первичный (промоушен прошёл, но метка не перехватилась или устарела) — забираю
          if claim "$APP" "$ME_ALIAS"; then
            log "$APP: метка перехвачена → $ME_ALIAS (я уже первичный, designated $designated мёртв)"
            designated="$ME_ALIAS"; D_IP="$ME_IP"
          fi
        elif [ -z "$rec" ]; then
          log "$APP: мой инстанс не отвечает — жду его возврата"
        fi
      fi
    fi

    # --- самоисцеление: метка на мне, а я стендбай → промоутим ---
    if [ "$designated" = "$ME_ALIAS" ] && [ "$inS" = 1 ] && [ "$rec" = t ]; then
      if promote_pg "$APP"; then
        claim "$APP" "$ME_ALIAS" || true
        log "$APP: ПРОМОУШЕН (самоисцеление: метка была на мне)"
      else
        log "$APP: promote (самоисцеление) не удался — повторим"
      fi
    fi

    # --- шаг назад старого первичного / перевешивание стендбая ---
    if [ "$designated" != "$ME_ALIAS" ] && [ -n "$rec" ] && [ -n "$D_IP" ]; then
      if [ "$rec" = f ]; then
        if tcp_ok "$D_IP" "$PORT"; then
          # большинство уже назначило другого И назначенный отвечает — ухожу в стендбай (CP)
          if pg_become_standby "$APP" "$D_IP"; then
            log "$APP: СТАРЫЙ ПЕРВИЧНЫЙ $ME_ALIAS встал стендбаем → $D_IP"
          else
            log "$APP: шаг назад не удался — повторим"
          fi
        else
          # designated мёртв/недоступен: НЕ ухожу в стендбай к мёртвому (рекординг-флэп из дрели).
          # Жду: либо я следующий по цепи и заберу метку в ветке назначения выше,
          # либо designated вернётся/будет перехвачен соседом — тогда шагну в следующем тике.
          log "$APP: designated $designated недоступен — шаг назад отложен (жду его возврата или claim)"
        fi
      elif [ "$rec" = t ] && [ -n "$D_IP" ] && tcp_ok "$D_IP" "$PORT"; then
        if ! pg_wal_target_ok "$APP" "$D_IP"; then
          if pg_become_standby "$APP" "$D_IP"; then
            log "$APP: стендбай перевешан на $D_IP"
          else
            log "$APP: перевешивание стендбая не удалось — повторим"
          fi
        fi
      fi
    fi

    # --- прокси: апстрим = текущий первичный ---
    if [ -n "$D_IP" ]; then
      pg_proxy_repoint "$APP" "$D_IP" || true
    fi

  else # ---------------- MongoDB ----------------
    mst="$(mongo_state "$APP")"
    [ -d "/var/lib/dbdata/mongo-$APP" ] && watch_instance "$APP" "$mst" "mongod-$APP"
    D_HOST=""; [ -n "$D_IP" ] && D_HOST="$D_IP:$PORT"
    MY_HOST="$ME_IP:$PORT"

    # --- назначение: объявлен мёртвым, я — следующий по цепи → заявляю метку ---
    if [ "$DEAD_DECLARED" = 1 ]; then
      nxt="$(next_of "$designated")"
      if [ -n "$nxt" ] && [ "$nxt" = "$ME_ALIAS" ] && [ "$inS" = 1 ]; then
        if [ "$mst" = 1 ] || [ "$mst" = 2 ]; then
          if claim "$APP" "$ME_ALIAS"; then
            log "$APP: метка перехвачена → $ME_ALIAS (первичный $designated объявлен мёртвым)"
            designated="$ME_ALIAS"; D_IP="$ME_IP"   # ниже ветки тика — уже про меня
          fi
        fi
      fi
    fi

    if [ "$mst" = 1 ]; then
      # я — первичный RS
      if [ "$designated" = "$ME_ALIAS" ]; then
        # я и назначенный: выровнять priority (1 — мне, 0 — остальным, арбитры не трогаем)
        out="$(mongo_reconfig_pri "$APP" "$MY_HOST" 0)"
        case "$out" in *err*) log "$APP: rs.reconfig: $out" ;; esac
      elif [ -n "$D_HOST" ] && tcp_ok "$D_IP" "$PORT"; then
        # первичный не назначенный: уступаю — выровнять priority, затем выборы RS
        mongo_reconfig_pri "$APP" "$D_HOST" 0 >/dev/null || true
        mongo_stepdown "$APP" >/dev/null || true
        log "$APP: НЕНАЗНАЧЕННЫЙ первичный $ME_ALIAS уступил (метка → $designated)"
      fi
    elif [ "$mst" = 2 ] && [ "$designated" = "$ME_ALIAS" ] && [ "$inS" = 1 ]; then
      # метка на мне, а я стендбай: если первичного в RS нет — перехватываю (force)
      if [ "$(mongo_primaries "$APP")" = 0 ]; then
        claim "$APP" "$ME_ALIAS" || true
        out="$(mongo_reconfig_pri "$APP" "$MY_HOST" 1)"
        case "$out" in *err*) log "$APP: force-reconfig: $out" ;; esac
        for i in $(seq 1 15); do
          if [ "$(mongo_state "$APP")" = 1 ]; then
            log "$APP: ПРОМОУШЕН — RS назначил $ME_ALIAS первичным"
            break
          fi
          sleep 1
        done
      fi
    fi
    # mst пустой/-1 (инстанс не отвечает / RS не поднят) и арбитры — без действий
  fi
done
exit 0
