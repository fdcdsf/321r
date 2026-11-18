#!/usr/bin/env bash
# 321r · шаг: Pangolin (панель доступа к сервисам) + Valkey + gerbil/traefik.
# Идемпотентен. Запускается с ноутбука/мастера: bash install/pangolin-up.sh
# Рендер конфигов идёт НА НОДАХ — пароли не покидают серверы.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [ -z "${DOMAIN:-}" ] || [ -z "${CF_API_TOKEN:-}" ]; then
  warn "DOMAIN или CF_API_TOKEN пусты — Pangolin без домена невозможен, шаг пропущен"
  exit 0
fi
EMAIL="${EMAIL:-admin@$DOMAIN}"
VALKEY_NODE="$CONTROL"
TRUSTED="$(for a in $(node_names); do node_ip "$a"; done | tr '\n' ','; for a in $(node_names); do node_mesh "$a"; done | tr '\n' ',' | sed 's/,$//')"
TRUSTED="${TRUSTED%,}"
ACME_NODE="$CONTROL"

step "Valkey (кэш Pangolin) на ноде $VALKEY_NODE"
if nssh "$VALKEY_NODE" 'docker ps --format "{{.Names}}" | grep -qx valkey'; then
  ok "valkey уже работает"
else
  nssh "$VALKEY_NODE" 'mkdir -p /opt/valkey /var/lib/dbdata/valkey'
  sed "s|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g" "$ROOT/stacks/valkey.yml" \
    | nssh "$VALKEY_NODE" 'cat > /opt/valkey/docker-compose.yml'
  nssh "$VALKEY_NODE" 'cd /opt/valkey && docker compose up -d' >/dev/null
  ok "valkey поднят ($(node_mesh "$VALKEY_NODE"):6379)"
fi

step "Секреты Pangolin (server.secret — один на кластер)"
SS_FILE="$SECRETS/pangolin-server-secret"
[ -f "$SS_FILE" ] || openssl rand -hex 24 > "$SS_FILE"
SS="$(cat "$SS_FILE")"
for a in $(node_names); do
  nssh "$a" "grep -q PANGOLIN_SERVER_SECRET /etc/db/secrets/pangolin.env 2>/dev/null \
      || echo 'PANGOLIN_SERVER_SECRET=$SS' >> /etc/db/secrets/pangolin.env
    chmod 600 /etc/db/secrets/pangolin.env
    grep -q APP_PASSWORD /etc/db/secrets/pangolin.env 2>/dev/null \
      || echo 'нет APP_PASSWORD — сначала шаг db (db-add pangolin)' >&2"
  ok "$a: pangolin.env готов"
done

step "Рендер /opt/pangolin и подъём (панель → gerbil/traefik)"
pids=(); bad=0
for a in $(node_names); do
  (
    nssh "$a" 'mkdir -p /opt/pangolin/config/{traefik,dynamic,certificates}'
    for f in config.yml.tmpl privateConfig.yml.tmpl traefik_config.yml.tmpl docker-compose.yml.tmpl; do
      ncp "$a" "$ROOT/deploy/pangolin/$f" "/opt/pangolin/$f"
    done
    ncp "$a" "$ROOT/deploy/pangolin/dynamic_config.yml" "/opt/pangolin/config/dynamic/dynamic_config.yml"
    acme=false; [ "$a" = "$ACME_NODE" ] && acme=true
    nssh "$a" "set -e
      cd /opt/pangolin
      APP_PASS=\$(grep '^APP_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"')
      SEC=\$(grep '^PANGOLIN_SERVER_SECRET=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"')
      sed -e \"s|__APP_DB_PASS__|\$APP_PASS|g\" -e \"s|__SERVER_SECRET__|\$SEC|g\" \
          -e 's|__EXTERNAL_IP__|$(node_ip "$a")|g' -e 's|__EXIT_NODE__|$a|g' \
          -e 's|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g' config.yml.tmpl > config/config.yml
      sed -e 's|__EMAIL__|$EMAIL|g' -e 's|__ACME__|$acme|g' \
          -e 's|10\.66\.0\.2|$(node_mesh "$VALKEY_NODE")|g' privateConfig.yml.tmpl > config/privateConfig.yml
      sed -e 's|__EMAIL__|$EMAIL|g' traefik_config.yml.tmpl > config/traefik/traefik_config.yml
      sed -e 's|__MESH_IP__|$(node_mesh "$a")|g' -e 's|__TRUSTED__|$TRUSTED|g' \
          docker-compose.yml.tmpl > docker-compose.yml
      chmod 600 config/config.yml config/privateConfig.yml
      docker compose up -d"
    echo "панель поднята"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "Pangolin поднялся не на всех нодах — смотрите вывод"

step "Лечение багов Pangolin (wildcard-repair) + cron"
for a in $(node_names); do
  nssh "$a" "/usr/local/bin/pangolin-wildcard-repair.sh $(node_ip "$a") >/dev/null 2>&1 || true
    cat > /etc/cron.d/321r-pangolin <<EOF
*/30 * * * * root /usr/local/bin/pangolin-wildcard-repair.sh $(node_ip "$a") >> /var/log/wildcard-repair.log 2>&1
EOF
    chmod 644 /etc/cron.d/321r-pangolin"
  ok "$a: repair после старта + каждые 30 мин"
done

step "Проверка"
sleep 10
for a in $(node_names); do
  st="$(nssh "$a" 'docker inspect -f "{{.State.Health.Status}}" pangolin 2>/dev/null || echo нет')"
  ok "$a: pangolin — $st"
done

cat <<EOF

  Pangolin поднят на всех нодах. Осталось руками (V1/00 → docs/pangolin-wildcard.md):
   1. открыть https://pangolin.$DOMAIN и пройти первичный онбординг (админ + 2FA);
   2. ввести EE-лицензию (панель → Settings);
   3. создать сайты cluster-<имя> нод и заложить их агенты (pangolin up site);
   4. ресурсы (komodo/rem/sub) — через панель или API с полным HC-набором.
EOF
