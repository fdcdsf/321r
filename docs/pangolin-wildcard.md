# Pangolin в кластере: ресурсы второго уровня (`nov.321r.ru`)

Диагноз, лечение и **требования к автоматическому установщику** (для реальных пользователей).
Проверено на Pangolin Enterprise **v2.3.4**, кластер 3 ноды, 2026-11-11.

## Что хотим

Сайт на домене второго уровня (`nov.321r.ru`, не `nov.app.321r.ru`), и один wildcard-сертификат
`*.321r.ru` на все такие имена сразу. В Pangolin это домен типа **wildcard**
(`base_domain: 321r.ru`, `prefer_wildcard_cert: true`).

## Домашний сервер за серым IP (подготовка, 2026-11-19)

Для будущего режима «Remnawave дома, ноды VPN на VPS» домашний Proxmox не должен
принимать входящие соединения из интернета. Создайте небольшой Debian/Ubuntu LXC,
в Pangolin создайте для него сайт типа **Newt** и запустите внутри LXC
`install/home-newt.sh` от root (терминал запросит адрес панели, ID и секрет сайта;
секрет хранится только в `/etc/newt/newt.env`, права 600). Newt создаёт исходящий
туннель к кластеру; после состояния Online можно направить ресурс `rem.<домен>`
на домашнюю панель. Официальная инструкция: `docs.pangolin.net/manage/sites/install-newt`.
LXC — уже контейнер: запускать внутри него ещё Docker ради одного Newt не требуется.
**Пока это подготовительный ручной путь**, а не законченная автоматизация установки
Proxmox/Remnawave и не проверка на домашнем железе.

## Корень проблемы: три бага Pangolin v2.3.4

Симптом «ресурсы wildcard-домена отвечают 404, сертификат — TRAEFIK DEFAULT CERT» — это
**не отсутствие маршрутизации**, а отсутствие сертификата. Лечится, но ручками.

### Баг 1. Двойная звёздочка при заказе сертификата

`createCertificate()` сохраняет строку сертификата с доменом `*.321r.ru` (при
`prefer_wildcard_cert: true`), затем `obtainCertificate → createOrder(cert.domain,
cert.wildcard)` **добавляет `*.` ещё раз** → Let's Encrypt получает идентификатор
`*.*.321r.ru` и отказывает:

```
Invalid identifiers requested :: Cannot issue for "*.*.321r.ru": Domain name has more than one wildcard
```

Строка остаётся в `status=failed` → ресурсы без сертификата → 404.

### Баг 2. Плейсхолдер «Server IP Address» в записях валидации

При создании wildcard-домена в `dnsRecords` пишется `value: "Server IP Address"` —
**буквальная строка**, не IP. Валидация сравнивает живые A-записи с этим значением
(`aRecords.includes(record.value)`) → всегда `0/2 records verified` → домен помечается
`failed` → создание ресурсов блокируется («Domain is not verified»). Панель при этом
показывает «Server IP Address» подставленным в IP инстанции — в базе остаётся плейсхолдер.

### Баг 3. `failed`-состояние не сбрасывается

После трёх неудач домен получает `failed=true, tries=N` и **пропускается валидатором
навсегда**; повторная выдача сертификата блокируется («Certificate already exists»).
Штатного сброса нет. `pangctl clear-certificates` (именно так, не `clear-certs`) удаляет
**все** строки сертификатов, включая валидные — пользоваться с осторожностью.

## Что лечит (доказано, nov6.321r.ru = 200 со всех трёх нод)

1. `certificates`: для wildcard-строки с доменом `*.base` **убрать префикс `*.`**
   (`domain = '321r.ru'`, `wildcard = true` остаётся) — тогда ACME получает корректные
   SAN `[321r.ru, *.321r.ru]` и Let's Encrypt выдаёт сертификат.
2. `dnsRecords`: заменить `value = 'Server IP Address'` на реальный IP из A-записей
   домена → валидация становится `2/2`.
3. Снять `failed=true, tries` с домена.

**Важно:** править БД только через VIP (`10.66.0.99`) — запись на стендбай упадёт с
«read-only transaction». И **не рестартовать pangolin после правки** — синхронизация
конфиг-домена при старте заново создаёт `dnsRecords` с плейсхолдером.

## Рецепт для автоматической установки (внимание: для реальных пользователей)

### 1. DNS-записи (до установки; через API регистратора)

| Запись | Тип | Значение |
|---|---|---|
| `<base>` | A | IP **всех** нод (мульти-A допустим: валидация — `includes`) |
| `*.<base>` | A | IP всех нод |
| `_acme-challenge.<base>` | NS | `dns.<base>` (встроенная DNS Pangolin) — без этого DNS-01 невозможен |
| `cname.<base>`, `site.<base>` | NS | `dns.<base>` (для CNAME/сайтовой DNS-зон) |

### 2. Конфигурация (шаблоны `deploy/pangolin/*.tmpl`)

`config.yml` — **одинаков на всех нодах**:

```yaml
traefik:
    cert_resolver: "letsencrypt"      # имя должно совпадать с резолвером в traefik
    prefer_wildcard_cert: true
flags:
    disable_config_managed_domains: false
domains:
    "<base>":
        base_domain: "<base>"
        prefer_wildcard_cert: true
        cert_resolver: "letsencrypt"
```

`privateConfig.yml`:

```yaml
flags: { enable_redis: true, use_pangolin_dns: true }
dns:
    enabled: true
    nameserver_name: "dns.<base>"
    cname_extension: "cname.<base>"
    site_extension: "site.<base>"
acme:
    cert_mode: "pangolin"            # сертификаты ресурсов — встроенный ACME через свою DNS
    contact_email: "<email>"
    enable_acme_client: true         # ТОЛЬКО на одной ноде кластера!
```

`traefik_config.yml` — резолвер `letsencrypt` с `dnsChallenge.provider: cloudflare`
(имя ждёт `config.yml` Pangolin; **сам дашборд с 2026-11-18 берёт файловый серт —
см. раздел ниже**, ACME traefik под NS-делегированием не работает).

Плюс: `server.secret` одинаковый на всех нодах, общий PostgreSQL и Valkey, уникальные
`gerbil.base_endpoint`/`exit_node_name`, `trusted-upstreams` со всеми адресами нод.

### 3. Обязательный шаг установщика: лечение багов

После старта pangolin (и по таймеру — плейсхолдер `dnsRecords` пересоздаётся при каждом
рестарте) запускать `scripts/pangolin-wildcard-repair.sh <IP>`:

```bash
scripts/pangolin-wildcard-repair.sh <один из IP A-записей>
```

Скрипт идемпотентен, пишет через VIP, чинит все три бага. Для systemd: `Type=oneshot`
+ `Restart=on-failure` по таймеру (например, раз в 5 минут) — это страховка и от
пересоздания плейсхолдера, и от гонок при создании новых ресурсов.

### 4. Проверка при установке

1. `docker exec ... certificates` → строка с `domain = <base>`, `wildcard = true`, `status = valid`.
2. `openssl s509` (см. ниже) — SAN содержит `<base>` и `*.<base>`.
3. Создать тестовый ресурс `test.<base>` → HTTPS отвечает **со всех трёх IP** (мульти-A).

```bash
curl -sk --resolve test.<base>:443:<node-ip> https://test.<base>/   # ожидание: 200
```

## Дашборд: сертификат через certbot, а не ACME traefik (2026-11-18, находка 35)

**Симптом:** `https://pangolin.<домен>` отдаёт `TRAEFIK DEFAULT CERT`, браузер блокирует;
в логах traefik — `Unable to obtain ACME certificate ... dns01: time limit exceeded ...
did not return the expected TXT record`.

**Корень:** NS-делегирование `_acme-challenge.<домен> → dns.<домен>` (оно нужно для
wildcard `*. <домен>`) перехватывает DNS-01 проверку **всех** имён вида
`_acme-challenge.*.<домен>` — включая `pangolin`. traefik пишет TXT через API Cloudflare,
а проверяющий резолвер идёт на `dns.<домен>` (встроенная DNS Pangolin), где этой записи
нет → отказ. certbot с `--dns-cloudflare` работает — путь проверен масками VPN.

**Лечение (в установщике, `install/pangolin-up.sh`):**

1. `certbot certonly --dns-cloudflare -d pangolin.<домен>` на каждой ноде;
2. `deploy/pangolin/panel_cert.yml` (`tls.certificates` → `/etc/letsencrypt/live/pangolin.<домен>/…`)
   кладётся в `config/dynamic/` — traefik берёт серт по SNI;
3. роутеры дашборда — `tls: {}` **без** `certResolver` (иначе traefik вечно долбит
   сломанный ACME и тратит лимиты Let's Encrypt);
4. продление: `certbot.timer` → хук `scripts/panel-cert-reload.sh` дописывает комментарий
   в `panel_cert.yml` → file provider (watch) перечитывает PEM; тот же хук делает
   `reload nginx`, чтобы маски VPN (серты `vpn-<нода>`/`tg`) тоже подхватывали
   продлённый PEM;
5. в `docker-compose.yml.tmpl` у traefik: `/etc/letsencrypt:/etc/letsencrypt:ro`;
6. проверка «не TRAEFIK DEFAULT CERT» — в шаге `pangolin` и в `install-check.sh` (§13).

Резолвер `letsencrypt` в `traefik_config.yml` оставлен: его имя ждёт `config.yml`
Pangolin (`cert_resolver`). На пустых серверах панель открывается сразу с валидным
сертом — до онбординга и до wildcard Pangolin.

## Ловушки (уже наступили на них)

- **Два разных механизма сертификатов.** `cert_mode: "pangolin"` — ресурсы (DNS-01
  встроенной DNS, сертификаты в PostgreSQL). `cert_resolver` в config.yml — роутеры
  Traefik (дашборд). Имена должны совпадать; не включать встроенный ACME на нескольких
  нодах (конфликт выдач).
- **БД — только через VIP первичного**; на стендбай — `read-only transaction`.
- **Не рестартовать pangolin после ручной правки БД** (синхронизация вернёт плейсхолдеры).
- `pangctl clear-certificates` сносит все сертификаты, включая валидные.
- Не смешивать UI-домен и config-домен для одного `base_domain`.
- traefik в `network_mode: service:gerbil`: пересоздавать их вместе
  (`docker compose up -d --force-recreate gerbil traefik`), одиночный restart gerbil
  рвёт сеть traefik.
- DOCKER-USER считает **контейнерные** порты (после DNAT): сверять публикации `host:container`
  с белым списком по порту контейнера.
- HTTP-01 не работает при мульти-A (Let's Encrypt multi-VA проверяет все IP) — для
  дашборда тоже нужен DNS-01.

## Устойчивость к ребутам (уроки теста «выключил все 3 сервера»)

**Новая пустая БД (находка 39, 2026-11-19):** в кластере три экземпляра
Pangolin используют общую PostgreSQL. Нельзя впервые запускать их одновременно:
все три выполняют Drizzle-миграции, операции `CREATE TABLE` конфликтуют,
проигравшие остаются `unhealthy` (Compose их не перезапускает). Установщик
`install/pangolin-up.sh` сначала рендерит конфиги на всех нодах, запускает
Pangolin на **одной** ноде и ждёт `healthy`, затем запускает остальные панели,
и только после них — gerbil/traefik. При повторе после неудачного старта
перезапускает unhealthy-панель, не трогая базу.

**Переустановка поверх работающих масок (находка 40):** `mask_config.yml` —
отдельный файл в `config/dynamic/`. После удаления `/opt/pangolin` пропадает
вместе с ним: дашборд отвечает, а mtproto/VPN теряют TCP-маршруты на :443.
После старта gerbil/traefik установщик восстанавливает маску, если mtproto
уже работает. В `mask_config.yml` адрес хоста внутри Docker-сети нельзя
жёстко задавать `172.22.0.1`: у c на тесте был `172.21.0.1`. Считывайте
gateway через `docker network inspect pangolin` на КАЖДОЙ ноде.

**Автонастройка после запуска (проверка на пустой БД):**
`scripts/pangolin-bootstrap.py` забирает setup token из логов, создаёт
администратора и организацию через API, пароль пишет в файл с правами 600;
`scripts/pangolin-sites.py` создаёт `cluster-<alias>` и сохраняет одноразовые
Newt-ключи; `install/pangolin-agents.sh` ставит Newt на ноды; после запуска
Komodo `scripts/pangolin-resources.py` создаёт ресурс и цель с полным HC.
Повторные запуски не перезаписывают существующих пользователей/сайты/цели.
Ручной режим остаётся через выбор в мастере. Прогон на трёх VPS подтвердил
сайты 3/3 online и цель Komodo healthy. До активации EE wildcard оставался
`pending`: сертификатный планировщик Pangolin не работает без подходящего уровня
лицензии. При вводе ключа в мастере установщик вызывает штатный
`POST /api/v1/license/activate` после создания админа; повторная активация
не выполняется. На тестовом кластере после активации wildcard получил
`valid`, HTTPS Komodo отвечает без `-k` на всех трёх IP. На случай отсутствия
лицензии установщик также может выдать **файловый** сертификат для конкретного
ресурса через `install/pangolin-resource-certs.sh komodo` (certbot DNS-01,
Cloudflare API; проверено на всех трёх нодах). Это не заменяет проверку
сайтов/маршрутов и не является лицензией EE.

Полный ребут кластера вскрыл три вещи, которые автоматический установщик обязан закрыть:

1. **`max_connections` в PostgreSQL.** Шаблон `db-add.sh` давал `max_connections=20` —
   три пула Pangolin (по 20 соединений на ноду) мгновенно исчерпали слоты
   (`FATAL: remaining connection slots are reserved...`) → Pangolin зависал, gerbil терял
   маршрутизацию, стендбай не мог подключить WAL-приёмник и крашился. **Норма: 200**
   (исправлено в `scripts/db-add.sh`).
2. **Docker не перезапускает unhealthy-контейнеры.** Pangolin, зависший при старте без БД,
   остаётся «жив, но мёртв» навсегда (healthcheck показывает unhealthy, рестарта нет).
   **Решение: `scripts/unhealthy-restart.sh`** — cron каждую минуту на каждой ноде
   перезапускает контейнеры в статусе unhealthy.
3. **Стендбай с расхождением timeline.** После ребут-шторма кластер меняет timeline; диск
   стендбая отстаёт → `FATAL: requested timeline N is not a child of this server's history`
   → краш-цикл. Это **штатное лечение, не авария**: пересборка basebackup ~1 мин.
   **Решение: `scripts/pg-rebuild-standby.sh [app]`** (запускать на больном узле; пишет
   через VIP, сам найдёт текущего первичного; применено — a снова `streaming`).
4. **Что выжило само:** Swarm, Mongo RS, слой БД (кроме случая 3), Komodo-стеки, все
   Pangolin-конфиги и сертификаты (монитор пересобрал их из PostgreSQL), wildcard-домен
   и его сертификат. Т.е. архитектура восстановления работает — нужна только автоматика
   трёх пунктов выше.

Итоговый набор cron для каждой ноды (уже стоит на стенде):

```cron
* * * * *   /usr/local/bin/unhealthy-restart.sh >>/var/log/unhealthy-restart.log 2>&1
*/30 * * * * /usr/local/bin/pangolin-wildcard-repair.sh <node-ip> >>/var/log/wildcard-repair.log 2>&1
```

## Что сообщить апстриму (fosrl/pangolin)

1. `createOrder` добавляет `*.` к уже wildcard-домену (`*.*.base`) при
   `prefer_wildcard_cert: true` — фикс: не добавлять префикс, если `domain` уже `*.`.
2. `dnsRecords.value` для wildcard-доменов пишется как `«Server IP Address»` —
   валидация не может пройти никогда.
3. `failed`-сертификаты не переиздаются («Certificate already exists» по любой строке,
   включая `failed`) + нет штатного сброса; `clear-certificates` сносит и валидные.

## 2026-11-12 · Ресурсы и туннели: уроки proxmox.321r.ru

**Симптомы (три маски одной болезни):**
- `503 no available server` (traefik) — за туннелем никто не слушает порт цели (агент со старым конфигом);
- `404 page not found` (gerbil) — цель unhealthy и отсечена фильтром, либо маршруты между нодами не сошлись;
- `000`/таймаут через одну ноду — та же причина про маршруты.

**Причины:**
1. Health-check цели, созданный через UI-мастер, приходит неполным (нет hcPath/hcPort/интервалов) →
   проверка падает → target unhealthy → `resolveExitNodes` не маршрутизирует (фильтр `hcHealth <> 'unhealthy'`).
   Внимание: цель БЕЗ строки HC тоже отсекается (SQL NULL <> 'unhealthy' = не проходит).
2. После удаления/пересоздания ресурсов агент (Newt/CLI) живёт со старым конфигом до ближайшего sync
   (рестарт агента, переподключение, смена секрета сайта).
3. WireGuard-туннель сайта держит одна нода, две другие пересылывают. После ребутов сходимость
   маршрутов занимает секунды–минуты: в это окно возможны 404.

**Лечение:**
- Обновить цель полным набором HC-полей: `POST /api/v1/target/{id}` c
  `hcEnabled:true, hcPath:'/', hcScheme:'https', hcMode:'http', hcHostname, hcPort,
  hcInterval:5, hcUnhealthyInterval:30, hcTimeout:5, hcMethod:'GET', hcFollowRedirects:true`
  (для самоподписанных сервисов backend `method:'https'`).
- Перезапустить агента на клиенте или перевыпустить секрет сайта — агент подтянет конфиг и отметит цель healthy.
- Дать маршрутам сойтись (1–2 мин) или перезапустить gerbil на «отстающей» ноде.

**Требования к инсталлятору (продукт):**
1. Создавать цели только полным HC-набором через API — не полагаться на дефолты UI-мастера.
2. Любое изменение ресурсов должно автоматически триггерить re-sync агентов (не требовать ручного рестарта).
3. Кросс-маршрутизация должна сходиться мгновенно (маршруты к чужим туннелям — из БД, без долгого кэша) —
   контролировать дриллом «нода ложится» (фаза 5).
4. Внешний мониторинг всех ресурсов по всем IP (фаза 8, Kuma).

**Апстрим:** поведение «цель без настроенного/здорового HC не маршрутизируется совсем» спорное —
кандидат в отчёт разработчикам Pangolin.
