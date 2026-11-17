#!/usr/bin/env bash
# 321r · УСТАНОВЩИК КЛАСТЕРА. Один запуск — весь кластер с нуля (V1/00, V1/22).
#
#   ./install.sh                  — мастер: спросит всё и установит
#   ./install.sh my.conf          — установка по готовому инвентарю
#   ./install.sh --from=db        — продолжить с шага (preflight|base|mesh|swarm|db|backup|tgbot|check|harden)
#   ./install.sh --check          — только автоприёмка
#   ./install.sh --manifest       — только перегенерировать cluster.yml из инвентаря
#
# Каждый шаг идемпотентен: повторный запуск ничего сломанного не оставит.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

FROM=""; CHECK_ONLY=""; MANIFEST_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --from=*) FROM="${arg#--from=}" ;;
    --check) CHECK_ONLY=1 ;;
    --manifest) MANIFEST_ONLY=1 ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) INV="$arg" ;;
  esac
done

# ---------- мастер: собрать инвентарь ----------
wizard() {
  echo "321r · установка кластера (новый пользователь)"
  echo "Отвечайте на вопросы; Enter = значение по умолчанию."
  CONF="$HERE/inventory.conf"
  local n=3 name ip role i=1
  read -rp "Сколько серверов (минимум 3) [$n]: " x; n="${x:-$n}"
  local nodes=()
  while [ "$i" -le "$n" ]; do
    def="$(printf "\\$(printf '%03o' $((96+i)))")"
    read -rp "Сервер $i: имя (короткое, напр. a) [$def]: " x
    name="${x:-$def}"
    read -rp "Сервер $i ($name): IP-адрес: " ip
    [ -n "$ip" ] || { echo "IP обязателен"; continue; }
    role="work"; [ "$i" = 1 ] && role="state"; [ "$i" = "$n" ] && role="bulk"
    nodes+=("$name $ip 10.66.0.$i $role")
    i=$((i+1))
  done
  read -rp "Нода команд бота (control) [${nodes[1]%% *}]: " x; CONTROL="${x:-${nodes[1]%% *}}"
  echo "Приложения (базы данных): по умолчанию pangolin(pg), remnawave(pg), komodo(mongo)."
  read -rp "Оставить как есть? [Y/n]: " x
  local apps=()
  if [ "${x:-y}" = "y" ] || [ "${x:-Y}" = "Y" ]; then
    apps=("pangolin pg 5432 a,b,c" "remnawave pg 5433 a,b,c" "komodo mongo 27017 a,b,c arbiter=a")
  else
    echo "Вводите по одному: имя engine(pg|mongo) порт placement (напр. myapp pg 5434 a,b,c). Пустая строка = конец."
    while read -rp "> " line; do [ -z "$line" ] && break; apps+=("$line"); done
  fi
  read -rp "Токен Telegram-бота (от @BotFather): " TG_BOT_TOKEN
  read -rp "Chat id владельца (от @userinfobot): " TG_CHAT_ID
  read -rp "Домен (можно пусто, если ставим только ядро): " DOMAIN
  read -rp "Cloudflare API-токен (можно пусто): " CF_API_TOKEN
  read -rp "Профиль ресурсов S/M/L [L]: " x; PROFILE="${x:-L}"
  {
    echo "# Сгенерировано мастером $(date -u +%F). Правьте — установщик перечитывает."
    echo "NODES=("
    printf '  "%s"\n' "${nodes[@]}"
    echo ")"
    echo "CONTROL=\"$CONTROL\""
    echo "VIP=\"10.66.0.99\""
    echo "APPS=("
    printf '  "%s"\n' "${apps[@]}"
    echo ")"
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\""
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\""
    echo "DOMAIN=\"$DOMAIN\""
    echo "CF_API_TOKEN=\"$CF_API_TOKEN\""
    echo "PROFILE=\"$PROFILE\""
    echo "BACKUP_WINDOWS=\"\""
    echo "SSH_KEY=\"\$HOME/.ssh/id_ed25519\""
  } > "$CONF"
  echo "Инвентарь сохранён: $CONF"
  INV="$CONF"
}

if [ -z "${INV:-}" ] && [ -f "$HERE/inventory.conf" ]; then INV="$HERE/inventory.conf"; fi
if [ -z "${INV:-}" ]; then
  if [ -t 0 ]; then wizard; else cp "$HERE/inventory.conf.example" "$HERE/inventory.conf" && INV="$HERE/inventory.conf"; fi
fi
export INV
# shellcheck source=/dev/null
source "$HERE/lib.sh"

# ---------- шаги ----------
step_preflight() {
  step "Предпроверки"
  [ -f "$SSH_KEY" ] || fail "нет ключа $SSH_KEY (создайте: ssh-keygen -t ed25519 и положите публичный на серверы — см. V1/00)"
  ok "локальный ключ: $SSH_KEY"
  detect_all_ports
  local a bad=0
  for a in $(node_names); do
    if [ "${NPORT[$a]}" = 0 ]; then warn "$a ($(node_ip "$a")): нет ssh-доступа ключом!"; bad=1; continue; fi
    local virt cont ram ker
    virt="$(nssh "$a" 'systemd-detect-virt --vm 2>/dev/null | head -1')"
    cont="$(nssh "$a" 'systemd-detect-virt --container 2>/dev/null | head -1')"
    ram="$(nssh "$a" 'free -m | awk "/Mem:/{print \$2}"')"
    ker="$(nssh "$a" 'uname -r')"
    if [ -n "$cont" ] && [ "$cont" != "none" ]; then
      warn "$a: виртуализация '$cont' (контейнерная) — AmneziaWG не встанет, нужна полная VM"; bad=1
    else
      ok "$a: виртуализация ${virt:-bare-metal}, RAM ${ram}МБ, ядро $ker"
    fi
    [ "${ram:-0}" -ge 900 ] || warn "$a: RAM ${ram}МБ — меньше честного минимума 1 ГБ (V1/20)"
  done
  [ "$bad" = 0 ] || fail "предпроверки не пройдены — исправьте и повторите (можно --from=preflight)"
  setup_cluster_key
}

step_base() {
  step "Базовая подготовка нод (пакеты, docker, ssh, firewall)"
  local a
  for a in $(node_names); do
    ncp "$a" -r "$ROOT/scripts/." "/usr/local/bin/"
    nssh "$a" 'chmod +x /usr/local/bin/*.sh'
    ncp "$a" "$ROOT/scripts/tgbot.py" "/usr/local/bin/tgbot.py"
    for u in "$ROOT"/systemd/*; do ncp "$a" "$u" "/etc/systemd/system/$(basename "$u")"; done
    nssh "$a" "bash -s -- $a $(node_mesh "$a") $VIP $PROFILE" < "$HERE/prepare-node.sh"
    ok "$a: базовая подготовка сделана"
  done
  detect_all_ports   # теперь все ноды отвечают на 2222
  render_manifest
}

render_manifest() {
  # cluster.yml — «прозрачный список серверов» (без секретов) → на все ноды
  local M="$ROOT/cluster.yml" a row arb
  {
    echo "# 321r · манифест кластера (генерирует install/install.sh из install/inventory.conf)"
    echo "# Правится руками или через инвентарь; копия — на нодах в /etc/db/cluster.yml; секретов нет."
    echo "cluster: 321r"
    echo "servers:"
    for a in $(node_names); do
      echo "  - {name: $a, ip: $(node_ip "$a"), geo: -, provider: -, size: $(echo "$PROFILE" | tr 'A-Z' 'a-z'), role: $(node_role "$a")}"
    done
    echo "control: $CONTROL   # «говорящая» нода бота (команды); алерты шлёт ЛЮБАЯ нода"
    echo "apps:"
    for row in "${APPS[@]}"; do
      arb="$(app_arbiter "$row")"
      printf '  - {name: %s, engine: %s, replicas: %s' "$(app_name "$row")" "$(app_engine "$row")" "$(app_placement "$row" | wc -w)"
      [ -n "$arb" ] && printf ', arbiter: 1'
      printf ', rule: "321"}\n'
    done
    echo "backup: {on: 2-other-domains, retention: {daily: 30, weekly: 12, monthly: 12}, export: telegram-monthly}"
    echo "survival: {policy: manual-via-bot, auto_after: null}"
  } > "$M"
  for a in $(node_names); do ncp "$a" "$M" "/etc/db/cluster.yml"; done
  ok "манифест cluster.yml разложен по нодам"
}

step_mesh()     { step "Меш AmneziaWG";        "$HERE/mesh-up.sh"; }
step_swarm()    { step "Docker Swarm";         "$HERE/swarm-up.sh"; }
step_db()       { step "Слой баз данных";      "$HERE/db-up.sh"; }
step_backup()   { step "Бэкапы 3-2-1";         "$HERE/backup-up.sh"; }
step_tgbot()    { step "Telegram-бот и дозор"; "$HERE/tgbot-up.sh"; }
step_check()    { step "Автоприёмка";          "$HERE/install-check.sh"; }
step_harden()   { step "Финальная защита ssh"
  local a
  for a in $(node_names); do
    nssh "$a" "sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
      sed -i 's/^#\\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
      grep -q '^Port 2222' /etc/ssh/sshd_config || echo 'Port 2222' >> /etc/ssh/sshd_config
      grep -q '^Port 22$' /etc/ssh/sshd_config && sed -i '/^Port 22$/d' /etc/ssh/sshd_config
      systemctl reload sshd 2>/dev/null || systemctl reload ssh
      ufw --force delete allow 22/tcp >/dev/null 2>&1 || true"
    ok "$a: парольный вход отключён, порт 22 закрыт"
  done
}

if [ -n "$MANIFEST_ONLY" ]; then
  detect_all_ports
  render_manifest
  exit 0
fi

STEPS=(preflight base mesh swarm db backup tgbot check harden)
started=1
[ -n "$FROM" ] && started=0
for s in "${STEPS[@]}"; do
  [ "$s" = "$FROM" ] && started=1
  [ "$started" = 1 ] || continue
  [ -n "$CHECK_ONLY" ] && [ "$s" != check ] && continue
  "step_${s}"
done

echo
echo "=========================================="
if [ -z "$CHECK_ONLY" ]; then
  echo "УСТАНОВКА ЗАВЕРШЕНА. Что дальше:"
  echo " 1. сверьте отчёт автоприёмки выше — все ✓?"
  echo " 2. панели (Pangolin/Remnawave/Komodo) — по докам docs/, если они вам нужны;"
  echo " 3. дриллы и эксплуатация — V1/17, V1/21; бот — @ваш_бот."
fi
echo "Повторная проверка: ./install.sh --check"
