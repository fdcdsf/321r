#!/usr/bin/env bash
# 321r · шаг: Remnawave (панель VPN) + 3 ноды Xray + маскировка (mtproto.zig) + egress.
# Идемпотентен. Запускается: bash install/remnawave-up.sh
# Требует: шаги db (pg remnawave) и dns (сертификаты DNS-01) уже пройдены.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ -n "${DOMAIN:-}" ] || { warn "нет DOMAIN — Remnawave/маски без домена невозможны, шаг пропущен"; exit 0; }
CTRL="$CONTROL"
RU_NODE="${RU_NODE:-$(node_names | head -1)}"   # нода в РФ: её Telegram-трафик уходит через зарубежную
GW_MESH="$(node_mesh "$CTRL")"
H="$ROOT/deploy/harvest"

step "Сертификаты маскировки (DNS-01, per node: vpn-<имя> + tg)"
# Урок: certbot в базовый набор не входит; без сертификатов nginx маски не стартует.
for a in $(node_names); do
  nssh "$a" 'command -v certbot >/dev/null 2>&1 || {
    for i in $(seq 1 30); do pgrep -x unattended-upgr >/dev/null 2>&1 || break; sleep 5; done
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=10 install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null; }'
  ok "$a: certbot готов"
done
pids=(); bad=0
for a in $(node_names); do
  (
    nssh "$a" "certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
        -d vpn-$a.$DOMAIN -d tg.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN 2>&1 | tail -4
      d=\$(ls -d /etc/letsencrypt/live/vpn-$a.* 2>/dev/null | head -1)
      if [ -n \"\$d\" ]; then
        ln -sfn \"\$d\" /etc/letsencrypt/live/mask
        echo \"сертификат: \$d\"
      else
        echo \"СЕРТИФИКАТ НЕ ВЫДАН — nginx маски не будет запущен\" >&2
        exit 1
      fi"
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
[ "$bad" = 0 ] || fail "без сертификатов маски не работают — смотрите вывод certbot выше"

step "nginx-заглушки маски (9447 http, 8448 ssl) + страница-приманка"
for a in $(node_names); do
  nssh "$a" 'command -v nginx >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq nginx >/dev/null; }'
  sed "s/tg\.321r\.ru/tg.$DOMAIN/g" "$H/nginx-mask.conf" | nssh "$a" 'cat > /etc/nginx/sites-enabled/mask'
  # Урок: дефолтный сайт nginx лезет на :80, а его держит gerbil Pangolin («bind() to
  # 0.0.0.0:80 failed»). Заглушке маски :80 не нужен — убираем. И учтите: nginx -t
  # занятые порты НЕ ловит — проверяем именно старт.
  nssh "$a" 'rm -f /etc/nginx/sites-enabled/default
    mkdir -p /var/www/mask
    [ -f /var/www/mask/index.html ] || echo "<html><body>Welcome</body></html>" > /var/www/mask/index.html
    nginx -t >/dev/null 2>&1 || { echo "nginx -t падает (нет сертификатов?)" >&2; exit 1; }
    systemctl restart nginx
    systemctl is-active --quiet nginx || { echo "nginx не стартовал (порт занят?)" >&2; exit 1; }'
  ok "$a: nginx-заглушки на месте"
done

step "Панель Remnawave на $CTRL (БД — наш VIP:5433)"
if nssh "$CTRL" 'docker ps --format "{{.Names}}" | grep -qx remnawave'; then
  ok "панель уже работает"
else
  nssh "$CTRL" 'mkdir -p /opt/remnawave/subscription /var/lib/dbdata'
  ncp "$CTRL" "$H/remnawave-compose.yml" /opt/remnawave/docker-compose.yml
  ncp "$CTRL" "$H/subpage-compose.yml" /opt/remnawave/subscription/docker-compose.yml
  nssh "$CTRL" 'set -e
    cd /opt/remnawave
    APP_PASS=$(grep "^APP_PASSWORD=" /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d "\"")
    SECRET=$(openssl rand -hex 24)
    METPASS=$(openssl rand -hex 10)
    cat > .env <<EOF
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
DATABASE_URL=postgresql://remnawave:${APP_PASS}@10.66.0.99:5433/remnawave
REDIS_SOCKET=/var/run/valkey/valkey.sock
APP_SECRET=${SECRET}
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
PANEL_DOMAIN=rem.'"$DOMAIN"'
FRONT_END_DOMAIN=rem.'"$DOMAIN"'
SUB_PUBLIC_DOMAIN=sub.'"$DOMAIN"'
METRICS_USER=metrics
METRICS_PASS=${METPASS}
WEBHOOK_ENABLED=false
SHORT_UUID_METHOD=nanoid
SERVICE_SNI_VERIFICATION=false
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${APP_PASS}
POSTGRES_DB=remnawave
EOF
    chmod 600 .env
    docker compose up -d'
  ok "панель поднята (первый старт — миграции, ~1-2 мин)"
fi

step "Заглушка HC для подписки (nginx 127.0.0.1:3011 на $CTRL)"
sed "s/sub\.321r\.ru/sub.$DOMAIN/g" "$H/nginx-subpage-hc.conf" | nssh "$CTRL" 'cat > /etc/nginx/sites-enabled/subpage-hc'
nssh "$CTRL" 'systemctl restart nginx'

step "VPN-ноды Xray (remnanode) ×3"
for a in $(node_names); do
  if nssh "$a" 'docker ps --format "{{.Names}}" | grep -qx remnanode'; then
    ok "$a: remnanode уже работает"
    continue
  fi
  nssh "$a" 'mkdir -p /opt/remnanode'
  ncp "$a" "$H/remnanode-compose.yml" /opt/remnanode/docker-compose.yml
  nssh "$a" 'ufw allow from 172.16.0.0/12 to any port 2099 proto tcp >/dev/null 2>&1
    ufw allow 2087/tcp >/dev/null 2>&1
    ufw allow from 172.16.0.0/12 to any port 9446 proto tcp >/dev/null 2>&1'
  ok "$a: remnanode расписан (SECRET_KEY и регистрация — следующий шаг, нужна панель)"
done

step "Маска Telegram (mtproto.zig) на всех нодах"
MSEC_FILE="$SECRETS/mtproto-secret"
[ -f "$MSEC_FILE" ] || openssl rand -hex 16 > "$MSEC_FILE"
MSEC="$(cat "$MSEC_FILE")"
pids=()
for a in $(node_names); do
  (
    nssh "$a" 'set -e
      if ! command -v mtbuddy >/dev/null 2>&1; then
        mkdir -p /tmp/mtb
        curl -fsSL https://github.com/sleep3r/mtproto.zig/releases/download/v1.15.4/mtbuddy-linux-x86_64.tar.gz | tar xz -C /tmp/mtb
        bin=$(find /tmp/mtb -type f -name "mtbuddy*" | head -1)
        install -m 755 "$bin" /usr/local/bin/mtbuddy
        rm -rf /tmp/mtb
      fi
      echo "mtbuddy: $(/usr/local/bin/mtbuddy --version 2>/dev/null | head -1 || echo есть)"'
    sed -e "s/tg\.321r\.ru/tg.$DOMAIN/g" -e "s/user = \".*\"/user = \"$MSEC\"/" "$H/mtproto-config.toml" \
      | nssh "$a" 'cat > /root/mtproto-config.toml'
    nssh "$a" 'if [ ! -x /opt/mtproto-proxy/mtproto-proxy ]; then
        /usr/local/bin/mtbuddy install --config /root/mtproto-config.toml --no-dpi --yes >/dev/null 2>&1 || true
      fi
      systemctl enable --now mtproto-proxy.service >/dev/null 2>&1 || true
      # mtbuddy сам открывает порт наружу — закрываем и открываем только от docker
      ufw status numbered | grep -E "8446.*ALLOW.*Anywhere" | cut -d"]" -f1 | tr -d " [" | sort -rn | xargs -r -n1 ufw --force delete >/dev/null 2>&1 || true
      ufw allow from 172.16.0.0/12 to any port 8446 proto tcp >/dev/null 2>&1 || true
      echo "mtproto: $(systemctl is-active mtproto-proxy.service 2>/dev/null || echo не-установлен)"'
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

step "WARP-туннель для mtproto (обход РКН; только mtproto)"
# Урок 2026-11-18: старая схема «tg-egress/mesh-egress через ноду-шлюз» не работает —
# все ноды кластера в РФ (проверено: geo RU у всех), чужой egress не спасает. WARP
# (обфусцированный WireGuard до Cloudflare) выводит трафик mtproto наружу с IP Cloudflare.
# Через WARP идёт ТОЛЬКО mtproto.zig (fwmark по uid пользователя mtproto), нода не страдает.
for a in $(node_names); do
  ncp "$a" "$ROOT/scripts/warp-321r.sh" /usr/local/bin/warp-321r.sh
  ncp "$a" "$H/warp.service" /etc/systemd/system/warp.service
  nssh "$a" 'chmod +x /usr/local/bin/warp-321r.sh
    systemctl daemon-reload
    systemctl enable warp.service >/dev/null 2>&1 || true'
done
# WARP-конфиг: из инвентаря (WARP_CONF — путь к файлу на мастере) или уже лежит на ноде
if [ -n "${WARP_CONF:-}" ] && [ -f "$WARP_CONF" ]; then
  for a in $(node_names); do
    ncp "$a" "$WARP_CONF" /etc/amnezia/amneziawg/warp.conf
    nssh "$a" 'chmod 600 /etc/amnezia/amneziawg/warp.conf'
  done
  ok "WARP-конфиг разложен по нодам (из $WARP_CONF)"
else
  warn "WARP_CONF не задан и конфига нет — mtproto без обхода (включите позже через бота)"
fi
pids=()
for a in $(node_names); do
  (
    if nssh "$a" '[ -f /etc/amnezia/amneziawg/warp.conf ]'; then
      nssh "$a" 'systemctl start warp.service >/dev/null 2>&1 || true
        sleep 1; /usr/local/bin/warp-321r.sh status' || echo "warp: не поднялся (см. awg show warp)"
    else
      echo "warp: нет конфига — пропущен"
    fi
  ) 2>&1 | sed "s/^/[$a] /" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
# старую схему сносим целиком (юниты, скрипты, маршруты, правку AllowedIPs в wg0.conf)
for a in $(node_names); do
  nssh "$a" 'systemctl disable --now tg-egress.service mesh-egress.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/tg-egress.service /etc/systemd/system/mesh-egress.service
    rm -f /usr/local/bin/tg-egress.sh /usr/local/bin/mesh-egress.sh
    systemctl daemon-reload
    ip route del 91.108.4.0/22 2>/dev/null || true
    ip route del 91.108.8.0/22 2>/dev/null || true
    ip route del 91.108.56.0/22 2>/dev/null || true
    ip route del 149.154.160.0/20 2>/dev/null || true'
done
nssh "$RU_NODE" "sed -i 's|, 91.108.4.0/22, 91.108.8.0/22, 91.108.56.0/22, 149.154.160.0/20||' /etc/amnezia/amneziawg/wg0.conf
  systemctl restart awg0.service" >/dev/null 2>&1 || warn "$RU_NODE: не удалось откатить AllowedIPs в wg0.conf"
ok "старая схема egress через $CTRL удалена; mtproto теперь через WARP"

step "Traefik-маска (passthrough vpn-* и tg)"
# Урок: force-recreate gerbil/traefik через compose НАДЕЖНО зависает (traefik живёт в
# netns gerbil). Динамические конфиги traefik перечитываются сами — достаточно
# рестарта самого traefik (gerbil не трогаем: его одиночный рестарт рвёт ingress).
for a in $(node_names); do
  sed -e "s/321r\.ru/$DOMAIN/g" "$H/mask_config.yml" | nssh "$a" 'cat > /opt/pangolin/config/dynamic/mask_config.yml'
  nssh "$a" 'docker restart traefik >/dev/null 2>&1 || true' &
done
wait
ok "маска подключена к traefik (матрица 3×3 на каждой ноде)"

cat <<EOF

  Remnawave + маскировка: инфраструктура готова. Осталось через панель/API
  (docs/remnawave.md, шаги идемпотентны):
   1. открыть https://rem.$DOMAIN (первый вход: admin/admin → сменить пароль, 2FA);
   2. Config Profile «321r-mask»: инбаунды masked-vless (:9446, fallback 9447,
      tls alpn http/1.1, decryption none) и reality-backup (:2087);
   3. зарегистрировать ноды: SECRET_KEY из GET /api/keygen → /opt/remnanode/.env →
      docker compose up -d; POST /api/nodes с configProfile;
   4. хосты (vpn-<имя>:443 и :2087 на каждый инбаунд), Internal Squad, пользователь
      (expireAt обязателен!) → подписка https://sub.$DOMAIN/api/sub/<shortUuid>;
   5. subpage: токен (POST /api/tokens, scopes ['*']) → /opt/remnawave/subscription/.env
      REMNAWAVE_API_TOKEN → docker compose up -d;
   6. ресурсы Pangolin rem.$DOMAIN → 127.0.0.1:3000, sub.$DOMAIN → 127.0.0.1:3010 (HC 3011).
  Ссылка маски Telegram: $(mtproto_link "tg.$DOMAIN" "$MSEC")
EOF
