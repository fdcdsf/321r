# Remnawave + маскировка: адаптация «xdom45» под проект 321r (фаза 9)

Создано: 2026-11-12. Статус: ДИЗАЙН (после раскатки — сверить с реальностью и отредактировать).
Источник вдохновения: «Документация по серверу xdom45.ru» (2026-08-01) — схема
VLESS+TLS+fallback на 443 под обычный сайт. См. также: V1/19-remnawave-vpn.md, PLAN.md §4 фаза 9.

## Идея (что берём с прошлого сервера)

Порт 443 каждой ноды выглядит для проверяющего (браузер, DPI-сканер) как **обычный сайт
с настоящим сертификатом**, но пропускает «своих» (VPN-клиент с ключом / Telegram-клиент
с секретом) к реальному сервису. Никаких «дырявых» портов с подозрительным TLS.

## Схема маршрутизации на 443 (наша кластерная версия)

```
Интернет :443 (любая из 3 нод, multi-A)
   │
   ▼
gerbil (SNI-прокси Pangolin)                        ← как traefik на старом сервере
   │
   ├─ SNI = ресурс Pangolin (komodo, proxmox, …) → туннель → Newt/агент
   ├─ SNI = pangolin.321r.ru → traefik → дашборд
   │
   ├─ SNI = vpn-<alias>.321r.ru → traefik TCP PASSTHROUGH (без расшифровки) → Xray :9446
   │        │
   │        ├─ VPN-клиент с верным ключом → VLESS-туннель (Remnawave node)
   │        └─ любой другой (fallback) → nginx :9447 → HTML-заглушка «обычный сайт»
   │
   ├─ SNI = 321r.ru → traefik TCP PASSTHROUGH → mtproto.zig :8446
   │        │
   │        ├─ Telegram-клиент с верным секретом → релей в Telegram
   │        └─ любой другой (mask) → nginx :8448 → та же HTML-заглушка
   │
   └─ SNI = rem.321r.ru → traefik → панель Remnawave (ресурс Pangolin)
```

Отличия от xdom45 (адаптация): SNI-маршрутизацию держит **gerbil → traefik** (у нас на 443
gerbil, не traefik напрямую); passthrough-правила — в нашем `dynamic_config.yml`
(`/opt/pangolin/config/traefik/dynamic_config.yml`), как и на старом; маскировка **на каждой
из 3 нод** (клиенты разносятся), а не на одной.

## Домены

| Домен | Роль | DNS | Сертификат |
|---|---|---|---|
| `vpn-a/b/c.321r.ru` | маска VPN-нод (VLESS+TLS+fallback) | wildcard `*.321r.ru` A×3 (уже есть!) | certbot DNS-01, per node |
| `tg.321r.ru` | маска Telegram-прокси (mtproto.zig) | wildcard `*.321r.ru` A×3 (уже есть) | certbot DNS-01, per node (SAN) |
| `rem.321r.ru` | панель Remnawave | CNAME → dns (есть) | сертификат Pangolin/traefik (авто) |
| `pangolin.321r.ru` | дашборд | есть | traefik (авто) |

DNS-правок не нужно: wildcard `*.321r.ru` + `321r.ru` уже A×3 (мульти-A живучесть).

## Порты (правка к PLAN §3!)

| Порт | Что | Статус |
|---|---|---|
| 443/tcp | gerbil → passthrough → Xray 9446 / mtproto 8446 (маскировка) | уже открыт |
| **2087/tcp** | **Reality (запасной VPN-канал)** | ОТКРЫТЬ новый |
| 9446 (loopback/host) | Xray VLESS+TLS+fallback | только с traefik/docker-подсети |
| 9447 (host) | nginx — HTML-заглушка VPN | только с Xray (localhost) |
| 8446 (host) | mtproto.zig | только с traefik/docker-подсети |
| 8448 (host) | nginx — HTML-заглушка mtproto | только с mtproto (localhost) |

⚠️ **Конфликт с планом:** план фазы 9 отдавал Reality-порту **2053**, но 2053 уже занят
запасным дашбордом Pangolin (compose публикует `2053:2053`). Reality переезжает на **2087**
(стандартный Cloudflare-портик). Исправить в PLAN.md §3 после раскатки.

Сервисы Xray/mtproto — `network_mode: host` (как на старом сервере), порты закрыты ufw
от мира; из контейнеров traefik достучится через docker-шлюз (`172.x.0.1`), нужен ufw-allow
от docker-подсети на 9446/8446 (см. «Грабли»).

## Сертификаты для маскировки

Маскировка требует **настоящий сертификат** на SNI-домен (иначе проверяющий увидит
самоподписной и поймёт). Берём certbot DNS-01 через Cloudflare API (токен тот же, что у ddns;
HTTP-01 при multi-A невозможен):

```bash
# на каждой ноде (плейсхолдеры рендерит установщик):
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d vpn-<alias>.321r.ru -d 321r.ru -m <email> --agree-tos -n
# файлы: /etc/letsencrypt/live/vpn-<alias>.321r.ru/{fullchain,privkey}.pem
# автопродление: штатный systemd-таймер certbot
```

Файлы монтируются в контейнеры (Xray, nginx) read-only. Wildcard-сертификат Pangolin
(`*.321r.ru` в PostgreSQL) для этого НЕ годится — он не выгружается файлами; certbot —
самостоятельный и проверенный путь (так было на xdom45).

## VPN-нода (remnawave/node = Xray) на каждой ноде

Compose `/opt/remnanode/docker-compose.yml`: образ `remnawave/node`, `network_mode: host`,
volume `/etc/letsencrypt:/etc/letsencrypt:ro`, env: адрес панели + секрет ноды.
Инбаунды задаются **панелью** (Config Profile):

1. **Основной — маскировка VLESS+TLS+fallback** (стиль xdom45):
   - listen 0.0.0.0:9446, protocol vless, tcp + tls (cert файлы маскировочного домена);
   - `fallbacks: [{dest: 9447}]` → nginx-заглушка;
   - клиент: `vless://<uuid>@vpn-<alias>.321r.ru:443?security=tls&sni=vpn-<alias>.321r.ru...`
     (порт 443 — через passthrough!).
2. **Запасной — Reality** (план фазы 9): порт **2087**, dest = реальный сайт (например
   www.microsoft.com), shortIds — генерирует панель. Стиль другой (не «обычный сайт на
   своём домене», а «чужой сайт»), держим в рукаве.

## Telegram-прокси (mtproto.zig) на каждой ноде

Образец: https://github.com/sleep3r/mtproto.zig (ставить через mtbuddy или напрямую).

- `/opt/mtproto-proxy/{mtproto-proxy,config.toml}`; порт **8446**, bind 0.0.0.0;
- `[censorship]`: `tls_domain = "tg.321r.ru"` (НЕ apex! см. грабли №7), `mask = true`,
  `mask_target = 127.0.0.1`, `mask_port = 8448` → nginx-заглушка (тот же HTML, что у VPN);
- **secret ОДИН на кластер** (клиенты ходят на любую ноду через multi-A — генерит установщик,
  хранит в `/etc/db/secrets/mtproto.env`, в чат/логи не попадает);
- systemd `mtproto-proxy`; ссылка для Telegram: `tg://proxy?server=tg.321r.ru&port=443&secret=...`
  (ФАКТ 2026-11-16: `mtbuddy links` выдаёт именно server=tg.321r.ru, port=443);
- **ufw: 8446 ТОЛЬКО от docker-подсети traefik!** mtbuddy при установке добавляет
  `8446/tcp ALLOW Anywhere` — это светит маску отдельным портом; правило убирать
  (`ufw delete allow 8446/tcp`), см. грабли/симптомы в V1/14;
- конфиг лежит в `/opt/mtproto-proxy/config.toml` (факт). Риск: `mtbuddy uninstall` сносит
  весь каталог вместе с секретами — перед удалением mtbuddy конфиг выгружать;
- **WARP-туннель НЕ нужен**: на старом сервере хостер резал egress к IP Telegram (свой косяк
  конкретного хостера); наших хостеров это не касается (проверить при раскатке:
  `curl --connect-timeout 5 https://149.154.167.51:443` с каждой ноды). Если какой-то хостер
  начнёт резать — WARP добавляем отдельным модулем (рецепт из xdom45 §5).

## Панель Remnawave — ДВА РЕЖИМА (выбор при установке!)

### Режим A: панель на домашнем сервере (как было)

- Панель живёт дома (compose), подключена к Pangolin через Newt-сайт `winwin` —
  ресурс `rem.321r.ru` → цель winwin.
- Ноды на VPS подключаются к панели по **публичному URL** `https://rem.321r.ru`
  (через наш Pangolin-кластер — работает и из РФ, и из-за рубежа).
- Плюсы: дома больше RAM на VPS; минусы: дом в критическом пути обновлений конфигов
  (VPN живёт по кешу), домашний интернет влияет на управление.

### Режим B: панель на наших серверах (план фазы 9) — основной для стенда

- Панель — compose на **b (VPS-2)** (~0.5–0.7 ГБ RAM, есть запас 8 ГБ).
- **MongoDB — через НАШ слой БД** (не «дикий» контейнер!): `apps.d/remnawave.yaml`
  (engine: mongo, placement: [b], класс: локальный) → `db-add remnawave` →
  инстанс с капами (wiredTiger 0.256, mem_limit 512M), адрес `10.66.0.99:270xx` (VIP).
  Бэкап-политика та же, что у всех (дампы → 2 соседние ноды).
- Доступ людей: ресурс Pangolin `rem.321r.ru` → site cluster-a/b/c → `127.0.0.1:<порт>`
  (как komodo.321r.ru), **полный HC у целей** (урок proxmox!). Без доп. авторизации Pangolin —
  секрет в URL подписки (иначе клиенты не смогут обновлять подписки).
- Агенты-ноды ходят к панели **по mesh** (`10.66.0.2:<порт>`) — без публичных портов.
- **Отказоустойчивость**: панель НЕ в критическом пути VPN — смерть b → xray на нодах
  работает по закешированному конфигу (VPN жив), обновления/новые подписки — ждут;
  панель восстанавливается как compose+БД (не перелетает — осознанно: mongo локальный на b).
- Пользовательский выбор при установке: `--panel=install` (режим B) или
  `--panel=connect:<url>` (режим A — просто регистрируем ноды в существующей панели).

## Как это войдёт в автоустановку (модульность)

```
bootstrap / cluster.sh up
  └─ модуль S8-VPN (опциональный, выбор при установке):
       1) спросить: панель — install | connect:<url>
       2) спросить: mtproto — да/нет
       3) certbot: сертификаты маскировки per node (идемпотентно)
       4) nginx-заглушки per node (шаблон HTML, идемпотентно)
       5) если install: apps.d/remnawave.yaml + db-add → compose панели на placement-ноде
          → admin (секреты генерируются на ноде) → ресурс rem.321r.ru через Pangolin API
       6) remnanode per node: compose + env (endpoint панели, секрет) → регистрация в панели
       7) traefik dynamic_config: tcp-passthrough блоки (vpn-<alias>, 321r.ru) → пересоздать
          gerbil+traefik ВМЕСТЕ (урок!)
       8) mtproto per node (если да): бинарник + config + secret + systemd
       9) ufw: 2087/tcp; allow от docker-подсети на 9446/8446
      10) проверки (ниже) → отчёт
```

Идемпотентность: каждый шаг — сверка-действие (cert уже есть? compose тот же? блок в
dynamic_config уже вставлен?). Выборы (панель/mtproto) — параметры, не вопросы в консоли
(`--panel=install --mtproto=yes`) — так работает unattended-установка.

## Проверки фазы 9 (по PLAN + наши)

- [ ] `https://vpn-a.321r.ru/` (и b, c) снаружи: **сайт-заглушка + валидный сертификат** (браузер без предупреждений!) — маскировка работает
- [ ] `https://321r.ru/` снаружи: та же заглушка (маска mtproto)
- [ ] Из РФ VPN поднимается на каждую ноду по очереди (подписки из панели)
- [ ] Через VPN открываются дашборд :8443 и ресурсы
- [ ] Reality на 2087 работает как запасной канал
- [ ] Telegram-прокси: клиент подключается по `tg://proxy?...`, трафик идёт
- [ ] Симуляция «b лежит»: xray не падает, VPN работает по кешу (панель недоступна)
- [ ] mtproto egress к Telegram без WARP (проверка curl к 149.154.167.51)

## Грабли xdom45 (переносим в наши требования)

1. `nginx reload` не всегда применяет конфиг → везде `systemctl restart nginx`.
2. «127.0.0.1 внутри контейнера ≠ хост»: traefik в контейнере достучится до host-сервисов
   только через docker-шлюз (`172.x.0.1`), сервисы слушают 0.0.0.0 + ufw-allow от
   docker-подсети (не только 172.18.0.0/16 — сверять свою подсеть!).
3. `ufw deny` бьёт и по своим — при недоступности первым делом `ufw status`.
4. YAML-отступы (dynamic_config.yml, compose) — сверять с соседними блоками; после правок
   `docker compose up -d --force-recreate gerbil traefik` (ТОЛЬКО вместе!).
5. Cookie/подмена Host — хрупко (у нас простая заглушка, без gate-trick — осознанно).
6. У нас добавляется: **gerbil перед traefik** — passthrough-правило живёт в
   `mask_config.yml` (ОТДЕЛЬНЫЙ файл в config/dynamic/ — Pangolin не затирает чужие файлы
   при записи своих роутеров!), проверка «доходит ли SNI до traefik» — первый тест раскатки.
   UFW: traefik (контейнер) → host-порт маскировки требует `ufw allow from 172.16.0.0/12
   to any port 9446|8446` (docker-подсеть на каждой нода своя: 172.21/172.22 — правило
   широкое, 172.16.0.0/12).
7. **NS-делегирование `_acme-challenge.321r.ru` ломает DNS-01 для apex через Cloudflare!**
   TXT создаётся в CF, но Let's Encrypt смотрит в нашу Pangolin-DNS (так работает wildcard).
   Правило: сертификаты certbot — только для поддоменов (vpn-*, tg.*), apex 321r.ru в SAN
   certbot НЕ включать (урок 2026-11-13: маска Telegram = `tg.321r.ru`, не apex).

## Правки к PLAN.md (внести после раскатки)

1. §3: Reality-порт 2053 → **2087** (2053 занят запасным дашбордом Pangolin).
2. Фаза 9: панель — с выбором режима (A: дом через туннель; B: наши серверы + наш слой БД);
   добавить mtproto.zig как опцию маскировки; заглушка — простая (без gate-trick).
3. Требования инсталлятору: модуль S8-VPN (выборы `--panel`, `--mtproto`), certbot DNS-01
   per node, passthrough-блоки в dynamic_config, ufw-allow от docker-подсети.

## Сверка с реальностью (раскатка 2026-11-12/13) — ПРАВКИ К ДИЗАЙНУ

Что оказалось иначе, чем в дизайне (факты проверены на стенде):

1. **Панель Remnawave v3.4.10 — на PostgreSQL (не MongoDB!)** и тянет штатный compose
   со своим postgres + valkey. Наше решение: **встроенный postgres ВЫКИНУТ**, панель ходит в
   НАШ слой БД: `apps.d/remnawave.yaml` (pg, class cluster, placement [b,c], primary b (стартовый),
   **port 5433**) → `db-add remnawave` → standby на c (streaming подтверждён), VIP-прокси,
   метки. Compose наш: `remnawave` + `remnawave-redis` (valkey, unix-socket).
   ФАКТ 2026-11-16: текущий первичный — **c** (метка `db-primary-remnawave=c`, standby b) —
   db-guard перенёс назначение; поле `primary:` в yaml — только бутстрап.
   **Лимиты памяти в compose обязательны** (бюджет — V1/20): `remnawave` —
   `NODE_OPTIONS=--max-old-space-size=320` (из коробки стоит 16384!) + `mem_limit: 640m`;
   subscription-page — heap 128 + `mem_limit: 256m` (142→95 МБ).
2. **Порты панели:** `127.0.0.1:3000:3000` (сама) и `127.0.0.1:3002:3001` (metrics).
   ⚠️ **3001 на хосте занят Uptime Kuma** (swarm-ingress на всех нодах) — metrics-маппинг
   обязателен на другой порт! Healthcheck панели: `GET :3001/health` внутри контейнера.
3. **ProxyCheckMiddleware убивает сокет** без `x-forwarded-for`/`x-forwarded-proto: https`
   (пустой ответ, не HTTP-ошибка). Прямой curl на 127.0.0.1:3000 — мёртв; **API зовём через
   `https://rem.321r.ru`** (наш traefik даёт нужные заголовки).
4. **Пароль админа — минимум 24 символа + спецсимволы** (валидация панели).
5. **API-авторизация (важно!):**
   - JWT админа (login/register) работает на `/api/*` ТОЛЬКО с заголовком
     **`X-Remnawave-Client-Type: browser`** (def-jwt-guard) — без него 403
     «For API requests you must create own API-token»;
   - для автоматизации — **API-токен**: `POST /api/tokens {"name","expiresInDays","scopes":["*"]}`;
     пустой `scopes: []` = нет прав (403 «Forbidden resource»); права:
     `GET /api/tokens/scopes` (wildcard `*` или `res:*`);
   - токен дальше: `Authorization: Bearer <API_TOKEN>` на всё, кроме 11 admin-only маршрутов.
6. **Ноды в панели:** `POST /api/nodes` требует
   `configProfile: {activeConfigProfileUuid, activeInbounds:[uuid,...]}` — UUID'ы инбаундов
   берутся из GET config-profiles (не путать с tag!).
7. **Маска Telegram = `tg.321r.ru`, НЕ apex** (см. грабли №7) — уже отражено выше.
8. **Egress к Telegram:** ноды b/c (зарубеж) ходят напрямую ✓; **нода a (РФ) — TCP к IP
   Telegram блокируется РКН** → для mtproto на a нужен egress-обход: маршрут /20 Telegram
   через mesh на b (ip route + SNAT) ИЛИ WARP-туннель (рецепт xdom45 §5). Выбираем mesh-обход.
9. **Секреты на нодах** (никуда не выгружать!): `/etc/db/secrets/remnawave-panel.env`
   (APP_SECRET, METRICS_PASS, WEBHOOK_SECRET_HEADER, ADMIN_USERNAME/ADMIN_PASSWORD, API_TOKEN,
   REALITY_PUB), БД-пароль — `/etc/db/secrets/remnawave.env` от db-add.
10. **Симлинк `/etc/letsencrypt/live/mask`** → cert-директорий ноды делает путь сертификата
    ОДИНАКОВЫМ на всех нодах — поэтому один config profile Xray работает на всех
    (certificateFile/keyFile = `/etc/letsencrypt/live/mask/*.pem`).

11. **Ноды VPN (remnanode):** панель коннектится К НОДЕ на `NODE_PORT` (не наоборот!):
    `POST /api/nodes` → `configProfile: {activeConfigProfileUuid, activeInbounds:[uuid,...]}`;
    секрет ноды — `GET /api/keygen` → `SECRET_KEY` в compose; `network_mode: host`,
    volume `/etc/letsencrypt:ro`. ⚠️ порт ноды (2099) слушает `rw-node` — ufw-правило
    `allow from 172.16.0.0/12 to any port 2099` ОБЯЗАТЕЛЬНО (панель в контейнере ходит на
    свой хост с docker-адреса, а не из mesh!).
12. **Xray 26.x требует `"decryption": "none"` во ВСЕХ vless-settings** (включая reality-инбаунд) —
    без этого «failed to build inbound handler» и краш-цикл.
13. **Fallback шлёт расшифрованный HTTP!** nginx-заглушка слушает ПРОСТОЙ http:9447
    (TLS терминирует сам Xray) — не ssl! (как и на xdom45: их nginx-блок без ssl_certificate).
14. **Маскировочным именам нужны свои A-записи** `vpn-<alias>.321r.ru` → IP своей ноды
    (не wildcard! иначе SNI vpn-b попадёт на ноду c → 404 и чужой сертификат = дыра в маске).
    TODO автоматизация: дописать в `ddns.sh` третью запись (vpn-<alias>).
15. **ssh без `-n` СЪЕДАЕТ stdin скрипта** (`bash -s` < file): всё после ssh-команды не
    выполняется молча! Всегда `ssh -n` внутри скриптов. `pkill -f "строка"` убивает собственный
    shell — маска `pkill -f "strin[g]"`.
16. **Хосты/сквады/подписки (порядок настройки):**
    - хост: `POST /api/hosts` `{inbound:{configProfileUuid, configProfileInboundUuid}, remark,
      address, port:443|2087, sni, securityLayer:"DEFAULT", fingerprint:"chrome", nodes:[uuid]}` —
      по одному хосту на ноду на инбаунд (всего 6);
    - сквад: `POST /api/internal-squads` `{name, inbounds:[inbound-uuid,...]}`;
    - юзер: `POST /api/users` `{username, expireAt}` (**expireAt обязателен!**) →
      `POST /api/internal-squads/{sq}/bulk-actions/add-users {"users":["<shortUuid>"]}`;
    - подписка: `https://rem.321r.ru/api/sub/<shortUuid>` (base64 с vless-ссылками).
    Без сквада подписка честно пишет «No hosts found — Check Internal Squads tab».

17. **Subscription Page (docs.rw/install/subscription-page/bundled):** отдельный сервис
    `remnawave/subscription-page` на b (`/opt/remnawave/subscription`, 127.0.0.1:3010),
    `REMNAWAVE_PANEL_URL=http://remnawave:3000` (docker-сеть), свой API-токен (`subpage`;
    создание токенов — admin-only маршрут: только JWT + `X-Remnawave-Client-Type: browser`!).
    Панель: `SUB_PUBLIC_DOMAIN=sub.321r.ru` (без схемы) + пересоздать контейнер.
    Доступ — ресурс Pangolin `sub.321r.ru` → cluster-b → 127.0.0.1:3010.
18. **Страница подписок «молчит» на всех путях кроме `/<shortUuid>`** (сокет глушится —
    защита от проверяющих). HC Pangolin не умеет заголовки → двойная адаптация:
    nginx-подкладка 127.0.0.1:3011 (добавляет X-Forwarded-*) для HC + постоянный
    пользователь-пробник `hc-probe`, HC path = `/<shortUuid hc-probe>` (порт 3011).
    Корень `sub.321r.ru` снаружи отдаёт 502 — НЕ ошибка, это дизайн приложения.
19. Пользовательская ссылка: `https://sub.321r.ru/<shortUuid>` (красивая страница с QR и
    кнопками клиентов); сырой `/api/sub/<shortUuid>` (base64) — для клиентов.
20. **404 на маске после выката (2026-11-13): причина — DNS-кэш.** Пока `vpn-*` попадали под
    wildcard `*.321r.ru` (3 IP), резолвер клиента отдавал ЧУЖИЕ ноды → traefik без такого SNI
    → 404. Фикс (и повышение живучести!): (а) certbot-сертификат маски = **4 SAN**
    (vpn-a+vpn-b+vpn-c+tg, `--expand`, имя каталога прежнее, симлинк `live/mask` жив);
    (б) в `mask_config.yml` — **три явных HostSNI-роутера** (vpn-a/b/c) на один сервис
    `mask-vpn` → локальный Xray. Теперь ЛЮБАЯ нода обслуживает ЛЮБОЕ имя (матрица 3×3 = 200).
    ⚠️ `HostRegexp` в traefik v3 для TCP НЕ поддерживается («unsupported function») —
    либо явные роутеры, либо `HostSNIRegexp`. A-записи vpn-* → свои IP оставлены (балансировка).
21. **mtproto.zig (mtbuddy v1.15.4):**
    - установка: `mtbuddy install --config <файл ВНЕ /opt/mtproto-proxy> --no-dpi --yes`
      (конфиг в самом каталоге установки → «are the same file»; `mtbuddy uninstall` сносит
      И сам mtbuddy — после него заново bootstrap!);
    - `--no-dpi` обязателен: его TCPMSS-фрагментация ClientHello сломала бы SNI-роутинг
      нашего passthrough, nfqws не нужен — анти-DPI уже в цепочке gerbil→traefik;
    - конфиг: порт 8446 (за passthrough), `public_ip=tg.321r.ru`, `public_port=443`,
      `[censorship] mask=true, mask_target=127.0.0.1, mask_port=8448` (наш nginx SSL!) —
      mtproto проксирует RAW TLS к маске; для Xray-fallback :9447 наоборот ПРОСТОЙ http
      (Xray терминирует TLS сам) — два РАЗНЫХ режима nginx!;
    - секрет — ОДИН на кластер (`/etc/db/secrets/mtproto.env`, multi-A) — клиенты ходят на любую ноду;
    - ⚠️ mtbuddy открывает ufw-порт — **закрыть обратно** (маскировка требует закрытого порта!).
22. **Egress mtproto из РФ (РКН блокирует IP Telegram):** трафик ноды a уходит через b:
    (а) маршруты Telegram-DC на a: 91.108.4.0/22, 91.108.8.0/22, 91.108.56.0/22,
    149.154.160.0/20 → via 10.66.0.2; (б) **главный подводный камень: AllowedIPs пира b
    в wg0.conf на a обязаны включать эти диапазоны** — WireGuard молча не пустит пакет вне
    AllowedIPs (маршрут есть, трафика нет — tcpdump пуст!); (в) на b: `ip_forward=1`,
    MASQUERADE для 10.66.0.0/24, `ufw route allow in on wg0 out on <iface>` (FORWARD default
    DROP у ufw). Persist: `tg-egress.service` (a), `mesh-egress.service` (b).
23. **«404 без сертификата» при открытии `vpn-a.321r.ru` БЕЗ `https://` (2026-11-13).**
    Браузер без схемы идёт на :80, а у маскировочных имён там не было роутера → gerbil
    отдавал 404 по чистому HTTP (о сертификате речи нет). Лечение обязательное: в
    `mask_config.yml` — секция `http:` с роутерами `Host(...)` на entrypoint `web` →
    `redirectScheme` (301) на https для vpn-a/b/c и tg. Проверка: `curl -s -o /dev/null -w
    '%{http_code} %{redirect_url}' http://vpn-a.321r.ru/` → `301 https://vpn-a.321r.ru/`.
    **Правило: каждый новый домен маскировки — сразу с http→https редиректом.**
24. **`ERR_HTTP2_PROTOCOL_ERROR` в браузере при живом curl-200 (2026-11-13).** Браузер по
    ALPN договаривается об HTTP/2, шлёт h2-фреймы, а fallback Xray отдаёт этот поток в
    nginx (HTTP/1.1) → обрыв. curl этого не видит (он по умолчанию на http/1.1!).
    Лечение обязательное: в конфиге `masked-vless` → `streamSettings.tlsSettings.alpn:
    ["http/1.1"]` (в config profile панели — ноды пересобирают конфиг сами).
    **Правило: тесты маскировки — ОБЯЗАТЕЛЬНО браузером, не только curl!**

**Проверено (2026-11-13):** маскировка vpn-*/tg = 200 со всех нод (матрица 3×3), VPN-ноды 3/3,
подписки и страница подписок работают, mtproto активен на a/b/c (маска tg = 200), egress из РФ
через b подтверждён. Осталось: дриллы фазы 5/9, обновление ddns.sh (A-записи маски),
PLAN.md, мелочи (2FA, пароли).



**Статус на 2026-11-13:** маскировочный каркас готов на a/b/c (certbot-серты `vpn-*`+`tg.*`,
nginx-заглушки 9447/8448, passthrough в `mask_config.yml`, ufw 2087 + 9446/8446 от docker);
панель на b работает (rem.321r.ru = 200 со всех нод), БД — наш слой [b,c]; профиль
`321r-mask` создан (inbounds: masked-vless 9446 + reality-backup 2087). В работе: ноды в
панели → remnanode на a/b/c → mtproto → проверки → PLAN.md.

---
*Статус: ДИЗАЙН от 2026-11-12, сверка с реальностью 2026-11-13 (обновлять при изменениях).*
