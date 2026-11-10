#!/usr/bin/env bash
# Мок-тест db-guard.sh: подменяем docker/iptables/logger/hostname/timeout/flock/ssh,
# проверяем логику назначения/фенса/прокси ПЕРЕД выкладкой на живые ноды.
set -u
SRC="/c/Users/user/Documents/vps/scripts/db-guard.sh"
ROOT=/tmp/dbgt
REAL_TIMEOUT=/usr/bin/timeout
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

make_sandbox() {
  SB="$ROOT/$1"
  rm -rf "$SB"
  mkdir -p "$SB/bin" "$SB/etc/db/apps.d" "$SB/etc/db/secrets" \
           "$SB/var/db-guard" "$SB/var/dbdata/pg-pangolin" "$SB/opt/db/proxy" "$SB/mock"
  cat > "$SB/etc/db/nodes.map" <<'EOF'
a 10.66.0.1 naval-chocolate.ptr.network
b 10.66.0.2 absent-coral.play2go.cloud
c 10.66.0.3 debian
EOF
  cat > "$SB/etc/db/apps.d/pangolin.yaml" <<'EOF'
name: pangolin
engine: pg
class: cluster
placement: [a, b, c]
primary: b
port: 59999
EOF
  echo "REPL_PASSWORD=test" > "$SB/etc/db/secrets/pangolin.env"

  # ---- стаб docker ----
  cat > "$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s docker %s\n' "$(date +%s)" "$*" >> "$MOCK/docker.log"
a=("$@")
case "${a[0]}" in
  info)
    case "$*" in
      *ControlAvailable*) echo true ;;
      *RemoteManagers*) echo "" ;;
    esac
    exit 0 ;;
  node)
    case "${a[1]}" in
      ls) exit "${MOCK_NODE_LS_RC:-0}" ;;
      update)
        target="${a[-1]}"
        i=0
        while [ "$i" -lt "${#a[@]}" ]; do
          case "${a[$i]}" in
            --label-add)
              kv="${a[$((i+1))]}"; k="${kv%%=*}"; v="${kv#*=}"
              case "$k" in
                vote.*) printf '%s' "$v" > "$MOCK/vote.${k#vote.}" ;;
                db-primary-*) printf '%s' "$v" > "$MOCK/label.${k#db-primary-}.${target}" ;;
              esac ;;
            --label-rm)
              k="${a[$((i+1))]}"
              case "$k" in db-primary-*) rm -f "$MOCK/label.${k#db-primary-}.${target}" ;; esac ;;
            --label-*)
              # как настоящий docker: неизвестный --label-* флаг → rc=125 (ловим баг класса
              # «--label-remove вместо --label-rm» ДО выкладки)
              echo "unknown flag: ${a[$i]}" >&2
              exit 125 ;;
          esac
          i=$((i+1))
        done
        exit 0 ;;
      inspect)
        fmt=""; i=0
        while [ "$i" -lt "${#a[@]}" ]; do
          case "${a[$i]}" in --format) fmt="${a[$((i+1))]}" ;; esac
          i=$((i+1))
        done
        target="${a[2]}"   # node inspect <имя> --format ...
        case "$fmt" in
          *vote.*)
            key="$(printf '%s' "$fmt" | sed -n 's/.*vote\.\([a-z0-9]*\.[a-z0-9]*\).*/\1/p')"
            printf '1;%s' "$(cat "$MOCK/vote.$key" 2>/dev/null || true)" ;;
          *db-primary-*)
            app="$(printf '%s' "$fmt" | sed -n 's/.*db-primary-\([a-z0-9]*\).*/\1/p')"
            cat "$MOCK/label.$app.$target" 2>/dev/null || true ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;
  exec)
    s="$*"
    case "$s" in
      *pg_is_in_recovery*) cat "$MOCK/pg.recovery" 2>/dev/null || printf 'f' ;;
      *pg_ctl\ promote*) printf 'f' > "$MOCK/pg.recovery"; exit 0 ;;
      *pg_stat_wal_receiver*) cat "$MOCK/pg.wal" 2>/dev/null || true ;;
      *primary_conninfo*) cat "$MOCK/pg.conninfo" 2>/dev/null || true ;;
      *mongosh*)
        case "$s" in
          *myState*) cat "$MOCK/m.mstate" 2>/dev/null || printf '%s' -1 ;;
          *stateStr*) cat "$MOCK/m.mprim" 2>/dev/null || printf '%s' -1 ;;
          *stepDown*) printf 'stepdown ok\n' ;;
          *"force: true"*) printf '1' > "$MOCK/m.mstate"; printf 'reconfig ok\n' ;;
          *rs.conf*) printf 'reconfig ok\n' ;;
        esac ;;
    esac
    exit 0 ;;
  restart)
    app="${a[1]#pg-}"
    if [ -f "$SB/var/dbdata/pg-$app/standby.signal" ]; then printf 't' > "$MOCK/pg.recovery"
    else printf 'f' > "$MOCK/pg.recovery"; fi
    exit 0 ;;
  inspect) printf 'true\n'; exit 0 ;;
  kill|compose) exit 0 ;;
esac
exit 0
STUB

  # ---- стаб iptables с состоянием правил ----
  cat > "$SB/bin/iptables" <<'STUB'
#!/usr/bin/env bash
printf '%s iptables %s\n' "$(date +%s)" "$*" >> "$MOCK/iptables.log"
cmd="$1"; shift
chain="$1"; shift
if [ -n "${1:-}" ] && [ "${1:-}" -eq "${1:-}" ] 2>/dev/null; then shift; fi
spec="$chain $*"
case "$cmd" in
  -C) grep -Fxq "$spec" "$MOCK/iptables.rules" 2>/dev/null ;;
  -I) printf '%s\n' "$spec" >> "$MOCK/iptables.rules" ;;
  -D) grep -Fxv "$spec" "$MOCK/iptables.rules" 2>/dev/null | grep . > "$MOCK/r.tmp" || true
      mv "$MOCK/r.tmp" "$MOCK/iptables.rules" 2>/dev/null || : ;;
esac
exit $?
STUB

  cat > "$SB/bin/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s logger %s\n' "$(date +%s)" "$*" >> "$MOCK/logger.log"
STUB
  cat > "$SB/bin/hostname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_HOSTNAME"
STUB
  cat > "$SB/bin/timeout" <<STUB
#!/usr/bin/env bash
case "\$*" in
  */dev/tcp/*) exit "\${MOCK_TCP_RC:-0}" ;;
esac
exec $REAL_TIMEOUT "\$@"
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/bin/flock"
  cat > "$SB/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s ssh %s\n' "$(date +%s)" "$*" >> "$MOCK/ssh.log"
exit "${MOCK_SSH_RC:-0}"
STUB
  chmod +x "$SB/bin/"*

  # ---- копия скрипта с переписанными путями ----
  sed -e "s|/etc/db|$SB/etc/db|g" \
      -e "s|/var/lib/db-guard|$SB/var/db-guard|g" \
      -e "s|/var/lib/dbdata|$SB/var/dbdata|g" \
      -e "s|/opt/db|$SB/opt/db|g" \
      "$SRC" > "$SB/db-guard.sh"
  bash -n "$SB/db-guard.sh" || { echo "bash -n ПРОВАЛЕН"; exit 1; }
}

run_guard() { # $1=сценарий $2=hostname $3=tcp_rc $4=ls_rc
  local sb="$ROOT/$1" rc
  PATH="$sb/bin:$PATH" MOCK="$sb/mock" SB="$sb" \
  MOCK_HOSTNAME="$2" MOCK_TCP_RC="$3" MOCK_NODE_LS_RC="${4:-0}" \
  bash "$sb/db-guard.sh" >/dev/null 2>&1
  rc=$?
  echo "$rc"
}

fresh_vote() { printf '%s' "1-$(date +%s)" > "$ROOT/$1/mock/vote.pangolin.$2"; }
dead_vote()  { printf '%s' "0-$(date +%s)" > "$ROOT/$1/mock/vote.pangolin.$2"; }

# ============ A: норма — я первичный, всё живо ============
echo "--- A: норма (b — первичный, жив) ---"
make_sandbox A
printf 'b' > "$ROOT/A/mock/label.pangolin.absent-coral.play2go.cloud"
printf 'f' > "$ROOT/A/mock/pg.recovery"
fresh_vote A a; fresh_vote A b; fresh_vote A c
rc="$(run_guard A absent-coral.play2go.cloud 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'ПРОМОУШЕН' "$ROOT/A/mock/logger.log" 2>/dev/null && bad "лишний промоушен" || ok "без промоушена"
grep -q 'pg_ctl promote' "$ROOT/A/mock/docker.log" 2>/dev/null && bad "лишний promote" || ok "promote не вызывался"

# ============ B: промоуш PG — b мёртв, я (c) — следующий ============
echo "--- B: промоуш PG (b мёртв, кандидат c) ---"
make_sandbox B
printf 'b' > "$ROOT/B/mock/label.pangolin.absent-coral.play2go.cloud"
printf 't' > "$ROOT/B/mock/pg.recovery"
dead_vote B a; dead_vote B b
rc="$(run_guard B debian 1 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'ПРОМОУШЕН' "$ROOT/B/mock/logger.log" && ok "лог ПРОМОУШЕН" || bad "нет лога промоушена"
grep -q 'pg_ctl promote' "$ROOT/B/mock/docker.log" && ok "вызван pg_ctl promote" || bad "promote не вызван"
grep -q -- '--label-rm db-primary-pangolin naval-chocolate' "$ROOT/B/mock/docker.log" \
  && bad "лишний label-rm a (метки на a нет — inspect-first пропускает)" \
  || ok "a пропущен (нет метки — не трогаем)"
grep -q -- '--label-rm db-primary-pangolin absent-coral' "$ROOT/B/mock/docker.log" \
  && ok "метка снята с b" || bad "label-rm b отсутствует"
grep -q -- '--label-add db-primary-pangolin=c' "$ROOT/B/mock/docker.log" \
  && ok "метка взята c" || bad "label-add c отсутствует"
[ "$(cat "$ROOT/B/mock/label.pangolin.debian" 2>/dev/null)" = c ] && ok "label-файл c=c" || bad "label-файл c"

# ============ C: фенс при потере кворума, C2: снятие ============
echo "--- C: фенс (кворум потерян >60с) ---"
make_sandbox C
echo $(( $(date +%s) - 61 )) > "$ROOT/C/var/db-guard/quorum.ok"
rc="$(run_guard C debian 0 1)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
n="$(grep -c -- '-I DOCKER-USER' "$ROOT/C/mock/iptables.log" 2>/dev/null || echo 0)"
[ "$n" = 3 ] && ok "вставлено 3 правила DROP" || bad "inserts=$n (ожидали 3)"
grep -q -- '-s 10.66.0.0/24 -j DROP' "$ROOT/C/mock/iptables.log" && ok "DROP -s mesh" || bad "нет DROP -s mesh"
grep -q -- '-d 10.66.0.0/24 -j DROP' "$ROOT/C/mock/iptables.log" && ok "DROP -d mesh" || bad "нет DROP -d mesh"
grep -q -- '-s 172.16.0.0/12 -j DROP' "$ROOT/C/mock/iptables.log" && ok "DROP -s 172.16/12 (локальный путь)" || bad "нет DROP 172.16/12"
grep -q 'ФЕНС' "$ROOT/C/mock/logger.log" && ok "лог ФЕНС" || bad "нет лога фенса"
[ -f "$ROOT/C/var/db-guard/fenced" ] && ok "файл fenced" || bad "нет файла fenced"

echo "--- C2: кворум вернулся — снятие фенса ---"
rc="$(run_guard C debian 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'ФЕНС снят' "$ROOT/C/mock/logger.log" && ok "лог снятия" || bad "нет лога снятия"
n="$(grep -c -- '-D DOCKER-USER' "$ROOT/C/mock/iptables.log" 2>/dev/null || echo 0)"
[ "$n" = 3 ] && ok "снято 3 правила" || bad "deletes=$n (ожидали 3)"
[ ! -f "$ROOT/C/var/db-guard/fenced" ] && ok "файл fenced удалён" || bad "fenced остался"
[ ! -s "$ROOT/C/mock/iptables.rules" ] && ok "правила пусты" || bad "правила остались: $(cat "$ROOT/C/mock/iptables.rules")"

# ============ D: mongo — перехват метки, затем force-reconfig ============
echo "--- D1: mongo, объявлен мёртвым, кандидат c заявляет метку ---"
make_sandbox D1
cat > "$ROOT/D1/etc/db/apps.d/komodo.yaml" <<'EOF'
name: komodo
engine: mongo
class: cluster
placement: [b, c]
primary: b
port: 59998
EOF
printf 'b' > "$ROOT/D1/mock/label.komodo.absent-coral.play2go.cloud"
printf '2' > "$ROOT/D1/mock/m.mstate"
printf '0' > "$ROOT/D1/mock/m.mprim"
printf '%s' "0-$(date +%s)" > "$ROOT/D1/mock/vote.komodo.a"
printf '%s' "0-$(date +%s)" > "$ROOT/D1/mock/vote.komodo.b"
rc="$(run_guard D1 debian 1 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'метка перехвачена' "$ROOT/D1/mock/logger.log" && ok "метка перехвачена" || bad "нет claim в логе"
[ "$(cat "$ROOT/D1/mock/label.komodo.debian" 2>/dev/null)" = c ] && ok "label-файл komodo c" || bad "label-файл komodo"

echo "--- D2: тик после claim — force-reconfig, RS назначает c ---"
rc="$(run_guard D1 debian 1 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'force: true' "$ROOT/D1/mock/docker.log" && ok "вызван force-reconfig" || bad "нет force-reconfig"
grep -q 'ПРОМОУШЕН — RS назначил' "$ROOT/D1/mock/logger.log" && ok "лог промоушена RS" || bad "нет лога RS"

# ============ E: шаг назад старого первичного ============
echo "--- E: старый первичный b встаёт стендбаем на c (c жив — tcp_ok) ---"
make_sandbox E
printf 'c' > "$ROOT/E/mock/label.pangolin.debian"
printf 'f' > "$ROOT/E/mock/pg.recovery"
fresh_vote E a; fresh_vote E b
rc="$(run_guard E absent-coral.play2go.cloud 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'СТАРЫЙ ПЕРВИЧНЫЙ' "$ROOT/E/mock/logger.log" && ok "лог шага назад" || bad "нет лога шага назад"
grep -q "host=10.66.0.3 port=59999" "$ROOT/E/var/dbdata/pg-pangolin/postgresql.auto.conf" 2>/dev/null \
  && ok "conninfo переписан на c" || bad "auto.conf не переписан"
[ -f "$ROOT/E/var/dbdata/pg-pangolin/standby.signal" ] && ok "standby.signal создан" || bad "нет standby.signal"
grep -q 'restart pg-pangolin' "$ROOT/E/mock/docker.log" && ok "контейнер перезапущен" || bad "нет restart"
[ "$(cat "$ROOT/E/mock/pg.recovery")" = t ] && ok "после рестарта — стендбай" || bad "recovery не t"

# ============ E2: флэп-защита — rec=f, designated мёртв, claim забирает метку ============
echo "--- E2: я уже первичный, метка устарела на мёртвом b — claim, БЕЗ шага назад ---"
make_sandbox E2
printf 'b' > "$ROOT/E2/mock/label.pangolin.absent-coral.play2go.cloud"   # устаревшая метка на b
printf 'f' > "$ROOT/E2/mock/pg.recovery"                                  # c уже первичный
dead_vote E2 a; dead_vote E2 b                                            # кворум «мёртв»
rc="$(run_guard E2 debian 1 0)"                                           # tcp до b падает
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'метка перехвачена' "$ROOT/E2/mock/logger.log" && ok "claim в логе" || bad "нет claim"
grep -q 'СТАРЫЙ ПЕРВИЧНЫЙ' "$ROOT/E2/mock/logger.log" && bad "шаг назад к мёртвому!" || ok "не демотирован к мёртвому"
[ "$(cat "$ROOT/E2/mock/label.pangolin.debian" 2>/dev/null)" = c ] && ok "метка у c" || bad "метка не у c"
[ ! -f "$ROOT/E2/mock/label.pangolin.absent-coral.play2go.cloud" ] && ok "устаревшая метка снята" || bad "устаревшая метка осталась"
[ ! -f "$ROOT/E2/var/dbdata/pg-pangolin/standby.signal" ] && ok "standby.signal не создан" || bad "standby.signal создан"
[ "$(cat "$ROOT/E2/mock/pg.recovery")" = f ] && ok "остался первичным" || bad "recovery изменился"
grep -q 'restart pg-pangolin' "$ROOT/E2/mock/docker.log" && bad "контейнер перезапущен" || ok "без рестарта"

# ============ E3: шаг назад отложен — designated мёртв, я не следующий по цепи ============
echo "--- E3: designated мёртв, я не кандидат — жду, не ухожу в стендбай ---"
make_sandbox E3
printf 'b' > "$ROOT/E3/mock/label.pangolin.absent-coral.play2go.cloud"   # метка на мёртвом b
printf 'f' > "$ROOT/E3/mock/pg.recovery"                                  # a «первичный» (окно гонки)
dead_vote E3 a; dead_vote E3 b
rc="$(run_guard E3 naval-chocolate.ptr.network 1 0)"                      # tcp до b падает; next_of(b)=c ≠ a
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'шаг назад отложен' "$ROOT/E3/mock/logger.log" && ok "лог отложенного шага" || bad "нет лога отложенного шага"
grep -q 'СТАРЫЙ ПЕРВИЧНЫЙ' "$ROOT/E3/mock/logger.log" && bad "шаг назад выполнен!" || ok "шаг назад не выполнен"
[ ! -f "$ROOT/E3/var/dbdata/pg-pangolin/standby.signal" ] && ok "standby.signal не создан" || bad "standby.signal создан"
[ "$(cat "$ROOT/E3/mock/pg.recovery")" = f ] && ok "остался первичным" || bad "recovery изменился"
grep -q 'restart pg-pangolin' "$ROOT/E3/mock/docker.log" && bad "контейнер перезапущен" || ok "без рестарта"

# ============ F: прокси переключается на текущий первичный ============
echo "--- F: апстрим прокси b→c ---"
make_sandbox F
printf 'c' > "$ROOT/F/mock/label.pangolin.debian"
printf 't' > "$ROOT/F/mock/pg.recovery"
printf 'host=10.66.0.3 port=59999 user=replicator password=x' > "$ROOT/F/mock/pg.conninfo"
fresh_vote F a; fresh_vote F b; fresh_vote F c
cat > "$ROOT/F/opt/db/proxy/haproxy.cfg" <<'EOF'
global
  log /dev/log local0
defaults
  mode tcp
# BEGIN pangolin
listen pg-pangolin
  bind 10.66.0.99:59999
  mode tcp
  server primary 10.66.0.2:59999 check
# END pangolin
EOF
rc="$(run_guard F naval-chocolate.ptr.network 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'server primary 10.66.0.3:59999' "$ROOT/F/opt/db/proxy/haproxy.cfg" && ok "апстрим переключён на c" || bad "апстрим не переключён"
grep -q 'апстрим прокси → 10.66.0.3' "$ROOT/F/mock/logger.log" && ok "лог переключения" || bad "нет лога переключения"
grep -q 'ПРОМОУШЕН' "$ROOT/F/mock/logger.log" && bad "лишний промоушен" || ok "без лишнего промоушена"
[ "$(stat -c %a "$ROOT/F/opt/db/proxy/haproxy.cfg")" = 644 ] && ok "права 644" || bad "права не 644"

# ============ G: ВЕРНЫЙ конфиг при мёртвом приёмнике — петли рестартов НЕТ ============
# Регрессия бага с ноды c: walreceiver мёртв (таймлайн 5≠1) → pg_stat_wal_receiver пуст,
# старая проверка врала «не перевешан» и зациклила рестарт каждые ~12 с. Проверяем КОНФИГ.
echo "--- G: стендбай с верным primary_conninfo, но мёртвым приёмником — без петли ---"
make_sandbox G
printf 'b' > "$ROOT/G/mock/label.pangolin.absent-coral.play2go.cloud"   # designated = b
printf 't' > "$ROOT/G/mock/pg.recovery"                                 # я стендбай (c)
printf 'host=10.66.0.2 port=59999 user=replicator password=x' > "$ROOT/G/mock/pg.conninfo"
# pg.wal НЕ создаём: приёмник не отвечает — как на c в дрели
fresh_vote G a; fresh_vote G b; fresh_vote G c
rc="$(run_guard G debian 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'restart pg-pangolin' "$ROOT/G/mock/docker.log" \
  && bad "рестарт при ВЕРНОМ конфиге (петля!)" || ok "без рестарта (конфиг верен)"
grep -q 'стендбай перевешан' "$ROOT/G/mock/logger.log" 2>/dev/null \
  && bad "лишнее перевешивание" || ok "не перевешивал"

# ============ G2: конфиг смотрит на СТАРОГО первичного — перевешивание ЕСТЬ ============
echo "--- G2: primary_conninfo указывает на старого — стендбай перевешивается ---"
make_sandbox G2
printf 'b' > "$ROOT/G2/mock/label.pangolin.absent-coral.play2go.cloud"  # designated = b (10.66.0.2)
printf 't' > "$ROOT/G2/mock/pg.recovery"                                # я стендбай
printf 'host=10.66.0.3 port=59999 user=replicator password=x' > "$ROOT/G2/mock/pg.conninfo"  # старый!
fresh_vote G2 a; fresh_vote G2 b; fresh_vote G2 c
rc="$(run_guard G2 debian 0 0)"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit=$rc"
grep -q 'стендбай перевешан на 10.66.0.2' "$ROOT/G2/mock/logger.log" \
  && ok "лог перевешивания на b" || bad "нет лога перевешивания"
grep -q "host=10.66.0.2 port=59999" "$ROOT/G2/var/dbdata/pg-pangolin/postgresql.auto.conf" 2>/dev/null \
  && ok "conninfo переписан на b" || bad "auto.conf не дополнен"
grep -q 'restart pg-pangolin' "$ROOT/G2/mock/docker.log" && ok "рестарт" || bad "нет рестарта"
[ "$(cat "$ROOT/G2/mock/pg.recovery")" = t ] && ok "остался стендбаем" || bad "recovery не t"

echo
echo "ИТОГ: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
