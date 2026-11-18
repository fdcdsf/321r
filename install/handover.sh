#!/usr/bin/env bash
# 321r · шаг: ПАМЯТКА ВЛАДЕЛЬЦА — все пароли, ключи, секреты и ссылки одним файлом.
# Файл кладётся на master-сервер (root, chmod 600) и отправляется владельцу в Telegram.
# Содержимое — СЕКРЕТЫ: в git не попадает, наружу не печатается (только путь к файлу).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CTRL="$CONTROL"
OUT="/root/321r-pamyatka-$(date +%F).txt"

step "Сбор секретов с нод"
# значения подхватываются в переменные, НЕ печатаются
R_PGPASS="$(nssh "$CTRL" "grep '^POSTGRES_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
R_APPPASS="$(nssh "$CTRL" "grep '^APP_PASSWORD=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
R_PGSERV="$(nssh "$CTRL" "grep '^PANGOLIN_SERVER_SECRET=' /etc/db/secrets/pangolin.env | cut -d= -f2- | tr -d '\"'")"
# код первичной настройки Pangolin — одноразовый; печатается в логах контейнера.
SETUP_TOK="$(nssh "$CTRL" 'docker logs --tail 4000 pangolin 2>&1 | grep -A1 "SETUP TOKEN" | grep "Token:" | awk "{print \$2}" | tail -1' 2>/dev/null || true)"
[ -n "$SETUP_TOK" ] && ok "setup token Pangolin получен (значение — только в файл)" || warn "setup token в логах не найден — похоже, первичная настройка уже пройдена"
RW_PASS="$(nssh "$CTRL" "grep '^APP_PASSWORD=' /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d '\"'")"
RW_PG="$(nssh "$CTRL" "grep '^POSTGRES_PASSWORD=' /etc/db/secrets/remnawave.env | cut -d= -f2- | tr -d '\"'")"
K_ADMIN="$(nssh "$CTRL" "grep '^KOMODO_INIT_ADMIN_PASSWORD=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_JWT="$(nssh "$CTRL" "grep '^KOMODO_JWT_SECRET=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_WEBHOOK="$(nssh "$CTRL" "grep '^KOMODO_WEBHOOK_SECRET=' /etc/db/secrets/komodo.env | cut -d= -f2-")"
K_CORE_KEY="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-keys/core.key')"
K_CORE_PUB="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-keys/core.pub')"
K_ONBOARD="$(nssh "$CTRL" 'cat /etc/db/secrets/komodo-onboarding.key')"
RESTIC="$(nssh "$CTRL" "grep '^RESTIC_PASSWORD=' /etc/db/secrets/restic.env | cut -d= -f2- | tr -d '\"'")"
CLUSTER_KEY="$(cat "$SECRETS/id_cluster" 2>/dev/null || echo '(нет)')"
MSEC="$(cat "$SECRETS/mtproto-secret" 2>/dev/null || echo '(нет)')"
TGTOK="${TG_BOT_TOKEN:-$(nssh "$CTRL" "grep '^TG_BOT_TOKEN=' /etc/db/secrets/telegram.env | cut -d= -f2- | tr -d '\"'")}"
ok "секреты собраны (значения — только в файл, не в вывод)"

step "Памятка владельца"
cat > "$OUT" <<EOF
================================================================================
 321r · ПАМЯТКА ВЛАДЕЛЬЦА — $(date -u '+%F %H:%M') UTC
================================================================================
⚠ ВСЁ НИЖЕ — СЕКРЕТЫ. Сохраните в надёжном месте (менеджер паролей / печать).
⚠ Не выкладывайте в git, облака и чаты. Утрата = пересоздание с нуля.

--- 1. СЕРВЕРЫ ---------------------------------------------------------------
ssh: порт 2222, пользователь root, вход ТОЛЬКО ключом (пароль отключён).
$(for a in $(node_names); do printf '  %s = %s (mesh %s)\n' "$a" "$(node_ip "$a")" "$(node_mesh "$a")"; done)
Ваш ssh-ключ: публичная часть установлена на всех серверах; приватный — у вас.
Ключ межнодового доступа (для восстановления доступа между серверами):
$CLUSTER_KEY

--- 2. TELEGRAM-БОТ ----------------------------------------------------------
  Токен:     $TGTOK
  Chat id:   ${TG_CHAT_ID:-см. /etc/db/secrets/telegram.env}

--- 3. БАЗЫ ДАННЫХ (общий адрес VIP $VIP) ------------------------------------
  pangolin  (pg,   :5432): пользователь pangolin / $R_APPPASS
                            postgres / $R_PGPASS
  remnawave (pg,   :5433): пользователь remnawave / $RW_PASS
                            postgres / $RW_PG
  komodo    (mongo, :27017): без авторизации (слышен только внутри меша)

--- 4. PANGOLIN --------------------------------------------------------------
  Панель:      https://pangolin.${DOMAIN:-<ваш-домен>} (первичный онбординг — вы задаёте админа)
  Код первичной настройки (setup token):
    ${SETUP_TOK:-(не найден в логах — настройка, похоже, уже пройдена)}
    взять самому: docker logs pangolin | grep -A1 "SETUP TOKEN"
    (актуален, пока не пройден первичный онбординг; если уже прошли — не требуется)
  server.secret: $R_PGSERV
  EE-лицензия: вводится в панели (Settings).

--- 5. KOMODO ---------------------------------------------------------------
  Панель:      https://komodo.${DOMAIN:-<ваш-домен>} (ресурс Pangolin → 127.0.0.1:9120)
  Вход:        admin / $K_ADMIN   (смените после первого входа + 2FA!)
  JWT-secret:  $K_JWT
  Webhook:     $K_WEBHOOK
  Ключ Core X25519 (pkcs8, БЕРЕГИТЕ — идентичность Core):
$K_CORE_KEY
  Публичный ключ Core: $K_CORE_PUB
  Onboarding-key периферии: $K_ONBOARD

--- 6. REMNAWAVE -------------------------------------------------------------
  Панель:      https://rem.${DOMAIN:-<ваш-домен>} (первый вход admin/admin → СМЕНИТЕ!)
  Подписка:    https://sub.${DOMAIN:-<ваш-домен>}/api/sub/<shortUuid>
  APP_SECRET (из .env на control): см. /opt/remnawave/.env
  Пароль БД:   $RW_PASS

--- 7. МАСКА TELEGRAM (mtproto.zig) ------------------------------------------
  Ссылка: tg://proxy?server=tg.${DOMAIN:-<ваш-домен>}&port=443&secret=$MSEC
  (секрет один на кластер; клиенты ходят на любую ноду)

--- 8. БЭКАПЫ (правило 3-2-1) -----------------------------------------------
  RESTIC_PASSWORD: $RESTIC
  ⚠ РАСПЕЧАТАЙТЕ ОФЛАЙН: без него копии бэкапов не прочитать!
  Копии: каждая нода пишет на 2 другие (/var/lib/backup-repos), ночью 03:10/03:40/04:10 UTC.
  Выгрузка на физический носитель: 1-го числа + кнопка в боте.

--- 9. CLOUDFLARE / ДОМЕН ----------------------------------------------------
  Домен:       ${DOMAIN:-<ваш-домен>}
  API-токен:   ${CF_API_TOKEN:-см. /etc/ddns.env на нодах}

--- 10. ГДЕ ВСЁ ЛЕЖИТ НА СЕРВЕРАХ -------------------------------------------
  /etc/db/secrets/          — пароли БД и сервисов (umask 077)
  /etc/db/cluster.yml       — манифест кластера (серверы/приложения)
  /opt/321r/install/inventory.conf — ваш инвентарь (мастер-сервер)
  /var/lib/backup-repos/    — репозитории бэкапов соседей
================================================================================
EOF
chmod 600 "$OUT"

# копия на control-ноду (файлохранилище кластера)
ncp "$CTRL" "$OUT" "/root/$(basename "$OUT")"
nssh "$CTRL" "chmod 600 /root/$(basename "$OUT")"

# отправка владельцу в Telegram (его же чат алертов)
if [ -n "${TG_CHAT_ID:-}" ] && [ -n "$TGTOK" ]; then
  curl -s -X POST "https://api.telegram.org/bot$TGTOK/sendDocument" \
    -F "chat_id=$TG_CHAT_ID" \
    -F "document=@$OUT" \
    -F "caption=🔐 Памятка 321r: пароли, ключи, ссылки. СОХРАНИТЕ В НАДЁЖНОМ МЕСТЕ!" >/dev/null && \
    ok "памятка отправлена вам в Telegram" || warn "не удалось отправить в Telegram (файл сохранён на сервере)"
else
  warn "нет TG_CHAT_ID — памятка только в файле на сервере"
fi

cat <<EOF

  🔐 ПАМЯТКА ВЛАДЕЛЬЦА ГОТОВА:
   - файл: $OUT (и копия на $CTRL: /root/$(basename "$OUT")), права 600;
   - отправлена вам в Telegram (сохраните в менеджер паролей / распечатайте!).
   В ней: доступы к серверам, токен бота, пароли баз, секреты Pangolin/Komodo/Remnawave,
   ключ Core, RESTIC-пароль, ссылка маски Telegram и Cloudflare-токен.
EOF
