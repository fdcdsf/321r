# Zabbix HA в 321r (отладочный прогон 2026-11-20)

Zabbix 7.0 LTS — **опциональный** слой мониторинга (GPL-2.0), не замена
Telegram-боту и db-guard. Профиль S не включает его: сервер и frontend
занимают память постоянно. Выбор — `ZABBIX_MODE=install`, отдельная PG-БД
`zabbix` в штатном реплицируемом слое 321r (VIP `:5434`).

## Как зайти

- URL: `https://zabbix.<домен>` (локальный Traefik каждой ноды → её `zabbix-web`).
- Логин `Admin`, пароль — в `/etc/db/secrets/zabbix-admin.json` на нодах и в
  памятке владельца (файл секретов, который бот шлёт в Telegram).
- Служебный пользователь `321r-bot` паролем не логинится — только для алертов.
- Пароли/секреты в git и в чат не попадают; памятку можно пересоздать:
  `bash install/handover.sh` (кладёт файл в `/root/` и шлёт в Telegram).

## HA и ресурсы

`server` запускается на **control (b)** и **standby (c)**, `web` — на **всех
трёх** нодах. `HANodeName` уникален, `NodeAddress` — mesh IP:10051. Оба сервера
видят одну БД; **работает только active**, standby держит HA manager и почти не
опрашивает сеть. Frontend не задаёт `ZBX_SERVER_HOST`, он берёт активный сервер
из БД. Агенты шлют `ServerActive=<mesh control>:10051;<mesh standby>:10051`
(точка с запятой = ОДИН HA-кластер; запятая создала бы два независимых).

Проверка на VPS с 6 ГБ: b active, c standby. После `docker stop zabbix-server`
на b c стала active (задержка failover ~60 с); после `docker start` b стала
standby, двух active не было. RSS Docker после прогрева: server 53 МиБ (active)
/ 4 МиБ (standby), web 44 МиБ, pg-zabbix 58–155 МиБ, агент2 28 МиБ на ноду.

Веб-доступ: `zabbix.<домен>` идёт через **локальный HTTP-роутер Traefik**
(`deploy/zabbix/traefik-local.yml`, priority 10000) на КАЖДОЙ ноде прямо в её
`zabbix-web:8080`. Это надёжнее, чем маршруты Pangolin file_mode: те генерируются
только для exit node с live-целью, и Newt мог подключиться к другому exit node
→ 503 при живом web (поймано в тесте). Сертификат — DNS-01 на каждой ноде.

## Мониторинг кластера

- Агент2 (официальный репозиторий Zabbix 7.0) на a/b/c, **только активные
  проверки** (`ListenIP=127.0.0.1`, внешнего :10050 нет).
- Шаблон `Linux by Zabbix agent active` + собственный `321r services`.
- LLD `cluster.services.discovery` каждые 5 мин, `lifetime 1h`: контейнеры
  Docker (без swarm task-имён `.\d+.<hex>`), enabled systemd-юниты, приложения
  из `/etc/db/apps.d`, доступность VIP:порт, свежесть бэкапа.
- HA-элементы на control: `cluster.ha.active`, `cluster.ha.standby` (из
  таблицы `ha_node` в общей БД) + триггеры «нет ровно одного active» (High) и
  «нет резерва» (Warning).
- На хосте по умолчанию «Zabbix server» шаблон Linux **снят** (`templates_clear`):
  агента на нём нет, поэтому триггер availability давал вечную ложную тревогу.

## Алерты в Telegram

Медиатип **Script** (`321r Telegram`) вызывает `tg-relay.sh` внутри контейнера
Zabbix-server. Скрипт читает `/run/secrets/zabbix-telegram.env` (зеркало
`/etc/db/secrets/zabbix-telegram.env`, chmod 640 под uid контейнера) и шлёт
через Bot API. **Токен не попадает в БД Zabbix, git или логи.**

Действие `321r: алерты в Telegram`: группа хостов `321r` + severity >= Average
(3). Recovery-операция шлёт «восстановлено». Отдельный пользователь `321r-bot`
НЕ в группе `Zabbix administrators` — иначе встроенное действие дублировало бы
сообщения. Проверено end-to-end: тестовый триггер → `alert.status=1` (sent).

## Важные места API Zabbix 7.0 (ламаются на мелочах)

- `mediatype.message_templates` = `[{eventsource, recovery, subject, message}]`,
  **не** `type` (recovery: 0=problem, 1=recovery).
- `user.update` принимает `medias` (в 5.2+ `user_medias` удалён); `sendto` для
  Script — строка, не массив.
- `action.create`: `opmessage` **не** принимает `subject`/`message` при
  `default_msg=1`; `recovery_operations` **не** принимает `evaltype`.
- `usergroup.create` не принимает `user_status`.
- `trigger.create` **не** принимает `hostid` — хост берётся из выражения.
- `event.acknowledge` с `action=1` (close) может вернуть «Application error»,
  но событие всё равно закрывается.
- Таблица HA-узлов в БД — `ha_node` (не `hanode`), столбцы
  `name,address,port,lastaccess,status` (3=active, 0=standby).
- `problem.get` не принимает `selectHosts`/`recent` вместе с `time_from`;
  надёжный вызов — только `output`/`limit`.

## Открытые вопросы

- Дедупликация с `tg-watch` (часовой дозор) и db-guard: сейчас Zabbix шлёт по
  severity >= Average, db-guard отвечает за кворум БД, tg-watch — за тренды.
- Подтверждение опасных действий из Zabbix UI (через бота) пока не делали.

Источники: [native HA](https://www.zabbix.com/documentation/7.0/en/manual/concepts/server/ha),
[контейнеры](https://www.zabbix.com/documentation/7.0/en/manual/installation/containers),
[авторегистрация](https://www.zabbix.com/documentation/7.0/en/manual/discovery/auto_registration),
[custom alert scripts](https://www.zabbix.com/documentation/7.0/en/manual/config/notifications/media/script),
[action object](https://www.zabbix.com/documentation/7.0/en/manual/api/reference/action/object).
