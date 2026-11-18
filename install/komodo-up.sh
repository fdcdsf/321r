#!/usr/bin/env bash
# 321r · шаг: Komodo (управление серверами): Core-стек + periphery на всех нодах.
# Идемпотентен. Запускается: bash install/komodo-up.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CTRL="$CONTROL"
CORE_ADDR="ws://$(node_mesh "$CTRL"):9120"

step "Секреты Komodo (docker secrets + копии в /etc/db/secrets)"
if nssh "$CTRL" 'docker secret ls --format "{{.Name}}" | grep -qx komodo-core-key'; then
  ok "docker secrets уже созданы — не пересоздаю (иначе periphery перестанут узнавать Core)"
else
  nssh "$CTRL" 'set -e
    mkdir -p /etc/db/secrets/komodo-keys
    umask 077
    openssl rand -base64 32 > /etc/db/secrets/komodo-keys/core.key
    openssl rand -base64 24 | tr -d "/+=" | head -c 28 > /etc/db/secrets/komodo.env.adminpass
    openssl rand -base64 32 > /etc/db/secrets/komodo.env.jwt
    openssl rand -base64 32 > /etc/db/secrets/komodo.env.webhook
    # core.pub (SPKI base64) из приватного — для пининга periphery
    python3 - <<PY
import base64, subprocess
raw = base64.b64decode(open("/etc/db/secrets/komodo-keys/core.key").read().strip())
der = bytes.fromhex("302e020100300506032b656e04220420") + raw
p = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"], input=der, capture_output=True)
open("/etc/db/secrets/komodo-keys/core.pub", "w").write(base64.b64encode(p.stdout).decode())
PY
    docker secret create komodo-core-key /etc/db/secrets/komodo-keys/core.key >/dev/null
    docker secret create komodo-jwt-secret /etc/db/secrets/komodo.env.jwt >/dev/null
    docker secret create komodo-webhook-secret /etc/db/secrets/komodo.env.webhook >/dev/null
    docker secret create komodo-admin-password /etc/db/secrets/komodo.env.adminpass >/dev/null
    {
      echo "KOMODO_INIT_ADMIN_USERNAME=admin"
      echo "KOMODO_INIT_ADMIN_PASSWORD=$(cat /etc/db/secrets/komodo.env.adminpass)"
      echo "KOMODO_JWT_SECRET=$(cat /etc/db/secrets/komodo.env.jwt)"
      echo "KOMODO_WEBHOOK_SECRET=$(cat /etc/db/secrets/komodo.env.webhook)"
    } > /etc/db/secrets/komodo.env
    chmod 600 /etc/db/secrets/komodo.env /etc/db/secrets/komodo-keys/*
    rm -f /etc/db/secrets/komodo.env.adminpass /etc/db/secrets/komodo.env.jwt /etc/db/secrets/komodo.env.webhook'
  ok "секреты созданы (пароль админа — в /etc/db/secrets/komodo.env на $CTRL)"
fi

step "Стек Komodo Core (на control-ноде, БД — VIP:27017)"
sed -e "s|komodo.321r.ru|komodo.${DOMAIN:-321r.ru}|g" \
    -e "s|node.labels.role != state|node.labels.name == $CTRL|" \
    "$ROOT/swarm/stacks/komodo-core.yaml" | nssh "$CTRL" 'cat > /tmp/komodo-core.yaml'
nssh "$CTRL" 'docker stack deploy -c /tmp/komodo-core.yaml komodo' 2>&1 | sed 's/^/  /'
ok "стек выкачен"

step "Ожидание Core и ключ onboarding"
for i in $(seq 1 30); do
  nssh "$CTRL" 'curl -sf -o /dev/null http://127.0.0.1:9120/' && break
  sleep 5
done
if nssh "$CTRL" '[ -s /etc/db/secrets/komodo-onboarding.key ]'; then
  ok "ключ onboarding уже есть"
else
  nssh "$CTRL" 'set -e
    PW=$(grep KOMODO_INIT_ADMIN_PASSWORD= /etc/db/secrets/komodo.env | cut -d= -f2-)
    JWT=$(curl -s -X POST http://127.0.0.1:9120/auth/login/LoginLocalUser \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"admin\",\"password\":\"$PW\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"jwt\",\"\"))")
    [ -n "$JWT" ] || { echo "не удалось войти в Core" >&2; exit 1; }
    curl -s -X POST http://127.0.0.1:9120/write/CreateOnboardingKey \
      -H "Authorization: $JWT" -H "Content-Type: application/json" \
      -d "{\"name\":\"321r-cluster\",\"expires\":0,\"tags\":[],\"privileged\":true,\"copy_server\":\"\",\"create_builder\":false}" \
      | python3 -c "import sys,json;open(\"/etc/db/secrets/komodo-onboarding.key\",\"w\").write(json.load(sys.stdin)[\"private_key\"])"
    chmod 600 /etc/db/secrets/komodo-onboarding.key'
  ok "ключ onboarding создан"
fi

step "Periphery на всех нодах (официальный setup-periphery.py)"
COPK="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-keys/core.pub')"
OBK="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-onboarding.key')"
pids=(); bad=0
for a in $(node_names); do
  (
    nssh "$a" "curl -fsSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py \
        | python3 - --core-address=$CORE_ADDR --connect-as=$a --onboarding-key=$OBK >/dev/null 2>&1 || true
      mkdir -p /etc/systemd/system/periphery.service.d
      printf '[Service]\nEnvironment=PERIPHERY_CORE_PUBLIC_KEYS=%s\n' '$COPK' > /etc/systemd/system/periphery.service.d/pin.conf
      systemctl daemon-reload
      systemctl enable periphery >/dev/null 2>&1
      systemctl restart periphery"
    sleep 6
    st="$(nssh "$a" 'systemctl is-active periphery')"
    echo "periphery: $st"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done

step "Сверка: серверы в панели"
sleep 5
nssh "$CTRL" 'set -e
  PW=$(grep KOMODO_INIT_ADMIN_PASSWORD= /etc/db/secrets/komodo.env | cut -d= -f2-)
  JWT=$(curl -s -X POST http://127.0.0.1:9120/auth/login/LoginLocalUser \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$PW\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"jwt\",\"\"))")
  curl -s -X POST http://127.0.0.1:9120/read/ListServers -H "Authorization: $JWT" -H "Content-Type: application/json" -d "{}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d if isinstance(d, list) else d.get(\"servers\", [])
print(\"  серверы:\", [(x.get(\"name\"), x.get(\"status\", \"?\")) for x in s])"' || warn "список серверов не получен (проверьте periphery)"

cat <<EOF

  Komodo готов. Осталось руками:
   1. ресурс Pangolin komodo.${DOMAIN:-321r.ru} → цель 127.0.0.1:9120 (полный HC-набор);
   2. вход: admin, пароль — /etc/db/secrets/komodo.env на ноде $CTRL (KOMODO_INIT_ADMIN_PASSWORD);
   3. смените пароль админа и включите 2FA.
EOF
