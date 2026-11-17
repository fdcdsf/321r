#!/usr/bin/env bash
# 321r install · общие помощники. Подключается (source) скриптами install/.
# Секреты установки (ключ нод) складываются в install/secrets/ — в git никогда.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
INV="${INV:-$HERE/inventory.conf}"
SECRETS="$HERE/secrets"

[ -f "$INV" ] || { echo "нет $INV: скопируйте install/inventory.conf.example или запустите ./install.sh (мастер)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$INV"

NODES=("${NODES[@]:-}")
APPS=("${APPS[@]:-}")
CONTROL="${CONTROL:-${NODES[1]%% *}}"
VIP="${VIP:-10.66.0.99}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PROFILE="${PROFILE:-L}"
BACKUP_WINDOWS="${BACKUP_WINDOWS:-}"

# ---------- вывод ----------
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  ✗ ОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

# ---------- инвентарь ----------
node_row() { local row; for row in "${NODES[@]}"; do case "$row" in "$1 "|"$1"|"$1 "*) echo "$row"; return;; esac; done; }
node_ip()   { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $2}'; }
node_mesh() { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $3}'; }
node_role() { local r; r="$(node_row "$1")"; echo "$r" | awk '{print $4}'; }
node_names() { local row; for row in "${NODES[@]}"; do echo "${row%% *}"; done; }

app_name()  { echo "${1%% *}"; }
app_engine() { echo "$1" | awk '{print $2}'; }
app_port()  { echo "$1" | awk '{print $3}'; }
app_placement() { echo "$1" | awk '{print $4}' | tr ',' ' '; }
app_arbiter() { echo "$1" | grep -oE 'arbiter=[a-z0-9_-]+' | cut -d= -f2 || true; }

app_row() { # $1=имя приложения
  local row; for row in "${APPS[@]}"; do [ "$(app_name "$row")" = "$1" ] && { echo "$row"; return; }; done
}
backup_window() { # $1=alias -> HH:MM (по умолчанию разнос по порядку: 03:10, 03:40, 04:10...)
  local w; w="$(grep -oE "(^| )$1=[0-9:]+" <<<"$BACKUP_WINDOWS" | awk -F= '{print $2}')"
  if [ -n "$w" ]; then echo "$w"; return; fi
  local i=0 n; for n in $(node_names); do [ "$n" = "$1" ] && break; i=$((i+1)); done
  printf '03:%02d' $((10 + 30*i))
}

# ---------- ssh к нодам ----------
declare -A NPORT=()
detect_port() { # $1=alias: 2222 (готовая нода) или 22 (свежая) или 0 (нет доступа)
  local a="$1" ip; ip="$(node_ip "$a")"
  # -n обязательно: проба не должна съедать stdin пайпа (урок: пустой telegram.env)
  if ssh -n -i "$SSH_KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null; then
    NPORT[$a]=2222
  elif ssh -n -i "$SSH_KEY" -p 22 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null; then
    NPORT[$a]=22
  else
    NPORT[$a]=0
  fi
}
detect_all_ports() { local a; for a in $(node_names); do detect_port "$a"; done; }

nssh() { # nssh <alias> <команда...>
  local a="$1"; shift
  [ -n "${NPORT[$a]:-}" ] || detect_port "$a"
  [ "${NPORT[$a]:-0}" != 0 ] || fail "нет ssh-доступа к ноде $a (см. V1/00: положите ключ)"
  ssh -i "$SSH_KEY" -p "${NPORT[$a]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
      "root@$(node_ip "$a")" "$@"
}
ncp() { # ncp <alias> <опции/файлы...> <куда на ноде>  (последний аргумент — путь на ноде!)
  local a="$1"; shift
  [ -n "${NPORT[$a]:-}" ] || detect_port "$a"
  [ "${NPORT[$a]:-0}" != 0 ] || fail "нет ssh-доступа к ноде $a"
  local n=$(( $# - 1 )) dest="${!#}"
  local -a srcs=( "${@:1:$n}" )
  scp -i "$SSH_KEY" -P "${NPORT[$a]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -q \
      "${srcs[@]}" "root@$(node_ip "$a"):$dest"
}

# ---------- ключ межнодового доступа (ноды ходят друг к другу сами) ----------
setup_cluster_key() {
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  [ -f "$SECRETS/id_cluster" ] || ssh-keygen -t ed25519 -N "" -f "$SECRETS/id_cluster" -C "321r-cluster" >/dev/null
  local a
  for a in $(node_names); do
    ncp "$a" "$SECRETS/id_cluster" "/root/.ssh/id_cluster"
    ncp "$a" "$SECRETS/id_cluster.pub" "/root/.ssh/id_cluster.pub"
    nssh "$a" 'chmod 600 /root/.ssh/id_cluster
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      grep -q "321r-cluster" /root/.ssh/authorized_keys 2>/dev/null || cat /root/.ssh/id_cluster.pub >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      cat > /root/.ssh/config <<EOF
Host 10.66.0.*
  Port 2222
  IdentityFile /root/.ssh/id_cluster
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /root/.ssh/known_hosts
Host *
  Port 2222
  IdentityFile /root/.ssh/id_cluster
  StrictHostKeyChecking accept-new
EOF
      chmod 600 /root/.ssh/config'
    ok "$a: ключ межнодового доступа положен"
  done
}
