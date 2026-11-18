#!/usr/bin/env bash
# 321r · подготовка ноды с нуля. Запускается НА ноде:
#   bash prepare-node.sh <имя> <mesh-ip> <vip> <профиль>
# Идемпотентен: повторный запуск ничего не ломает (проверяет каждое действие).
set -euo pipefail
umask 022

ALIAS="${1:?имя ноды}"; MESH_IP="${2:?mesh-ip}"; VIP="${3:-10.66.0.99}"; PROFILE="${4:-L}"

echo "== $ALIAS: базовая подготовка ($MESH_IP, профиль $PROFILE) =="

# --- 0) предпроверки (урок: контейнерные виртуализации OpenVZ/LXC = AmneziaWG не встанет;
#        kvm/vmware/hyperv и прочие полные VM — годятся) ---
VIRT="$(systemd-detect-virt --vm 2>/dev/null | head -1 || true)"
CONT="$(systemd-detect-virt --container 2>/dev/null | head -1 || true)"
if [ -n "$CONT" ] && [ "$CONT" != "none" ]; then
  echo "  ! виртуализация '$CONT' (контейнерная) — нужна полная VM" >&2
else
  echo "  виртуализация: $VIRT ✓"
fi

# --- 1) hostname = короткое имя (по нему идёт маппинг нод; только на СВЕЖЕЙ ноде) ---
if [ ! -f /etc/db/nodes.map ]; then
  hostnamectl set-hostname "$ALIAS"
  echo "  hostname: $ALIAS"
else
  echo "  hostname не трогаем (нода уже в кластере)"
fi

# --- 2) пакеты и Docker ---
export DEBIAN_FRONTEND=noninteractive
# Свежая Ubuntu при первом старте держит dpkg-лок (unattended-upgrades) — ждём и
# ретраим (урок полевого теста: «Could not get lock /var/lib/dpkg/lock-frontend»).
for i in $(seq 1 60); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 10; done
apt_retry() { local n; for n in $(seq 1 10); do "$@" && return 0; echo "  apt занят — жду 15 с (попытка $n)"; sleep 15; done; return 1; }
APTQ="apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10"
apt_retry $APTQ update -qq
apt_retry $APTQ install -y -qq ca-certificates curl gnupg git jq python3 ufw fail2ban \
  dkms "linux-headers-$(uname -r)" tar gzip util-linux restic >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg   # иначе gpg спросит «перезаписать?» через /dev/tty
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_retry $APTQ update -qq
  apt_retry $APTQ install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
fi
docker version --format '  docker {{.Server.Version}} ✓'

# --- 3) часы UTC (урок: CET = «разбег часов» между нодами) и NTP ---
timedatectl set-timezone UTC
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

# --- 4) лимиты логов (урок: json.log дорос до 1.5 ГБ) ---
mkdir -p /etc/docker
if ! grep -q 'max-size' /etc/docker/daemon.json 2>/dev/null; then
  echo '{"log-opts": {"max-size": "20m", "max-file": "3"}}' > /etc/docker/daemon.json
fi
systemctl reload docker 2>/dev/null || systemctl restart docker
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/321r.conf
systemctl restart systemd-journald
cat > /etc/logrotate.d/docker-containers <<'EOF'
/var/lib/docker/containers/*/*-json.log {
  size 200M
  copytruncate
  missingok
  notifempty
  rotate 3
}
EOF
sysctl -qw vm.swappiness=10
grep -q 'vm.swappiness' /etc/sysctl.d/99-321r.conf 2>/dev/null || echo 'vm.swappiness=10' > /etc/sysctl.d/99-321r.conf

# --- 5) ssh: порт 2222 (пароль НЕ трогаем — отключает финальный шаг harden,
#        и только если заложен ключ пользователя; урок: прерванная установка
#        без пароля = потеря доступа) ---
SSHD=/etc/ssh/sshd_config
grep -q '^Port 2222' "$SSHD" || echo 'Port 2222' >> "$SSHD"
grep -q '^Port 22$' "$SSHD" || echo 'Port 22' >> "$SSHD"    # временно, пока ключевой вход не подтверждён
grep -q '^MaxAuthTries' "$SSHD" && sed -i 's/^MaxAuthTries .*/MaxAuthTries 3/' "$SSHD" || echo 'MaxAuthTries 3' >> "$SSHD"
systemctl reload sshd 2>/dev/null || systemctl reload ssh

# --- 6) firewall ---
ufw allow 2222/tcp >/dev/null
ufw allow 22/tcp >/dev/null            # временно; закроет шаг harden
ufw allow from 10.66.0.0/24 >/dev/null # меш = доверенная зона
case "$PROFILE" in
  S) : ;;
  *)
    ufw allow 80,443,8443,2053,2087/tcp >/dev/null
    ufw limit 53/udp >/dev/null
    ufw allow 51820,21820/udp >/dev/null
    ;;
esac
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null

# --- 7) fail2ban ---
cat > /etc/fail2ban/jail.d/321r.conf <<EOF
[sshd]
enabled = true
port = 2222
maxretry = 3
bantime = 1h
ignoreip = 127.0.0.1/8 10.66.0.0/24
EOF
systemctl enable --now fail2ban >/dev/null

# --- 8) каталоги кластера (урок: umask 077 на секреты) ---
install -d -m 700 /etc/db/secrets /etc/db/apps.d
install -d -m 755 /var/lib/dbdata /var/lib/pgwal /var/lib/pgbackup /var/lib/backup-repos /opt/db
install -d -m 700 /var/lib/db-guard /var/lib/tgbot

echo "  подготовка $ALIAS завершена"
