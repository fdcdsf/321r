# 16 — Шпаргалки: API и команды

Обновлено: 2026-11-12. См. также: [03-факты](03-факты.md), [14](14-troubleshooting.md).

## Pangolin API (панель, порт 443/8443)

Сессия — из браузера (куки логина); **обязательный заголовок**:
`X-CSRF-Token: x-csrf-protection` (статическая строка) + `Content-Type: application/json`.
База: `https://pangolin.321r.ru`, org — `testopg` (на стенде).

| Задача | Вызов |
|---|---|
| Список сайтов-агентов | `GET /api/v1/org/testopg/sites` |
| Список ресурсов | `GET /api/v1/org/testopg/resources` |
| Создать домен | `PUT /api/v1/org/testopg/domain` |
| Удалить домен | `DELETE /api/v1/org/testopg/domain/{id}` |
| Создать ресурс | `PUT /api/v1/org/testopg/resource` (name, subdomain, domainId, mode) |
| Обновить ресурс | `PUT /api/v1/resource` |
| Добавить цель | `PUT /api/v1/resource/{id}/target` (siteId, ip, port, method, hc*) |
| Обновить цель | `POST /api/v1/target/{id}` |
| Цели ресурса | `GET /api/v1/resource/{id}/targets` |
| DNS-записи | `GET/DELETE /api/v1/org/testopg/dns-records` |

Полный набор HC-полей для цели (обязательно!):

```json
{"siteId": 1, "mode": "http", "method": "https", "ip": "192.168.1.100", "port": 8006,
 "enabled": true, "pathMatchType": "prefix", "path": "/",
 "rewritePathType": "prefix", "rewritePath": "/", "priority": 1,
 "hcEnabled": true, "hcPath": "/", "hcScheme": "https", "hcMode": "http",
 "hcHostname": "192.168.1.100", "hcPort": 8006, "hcInterval": 5,
 "hcUnhealthyInterval": 30, "hcTimeout": 5, "hcMethod": "GET", "hcFollowRedirects": true}
```

## Komodo API (Core, порт 9120)

**Тело — ПРОСТОЕ (params), НЕ wrapped** (wrapped на голом `/auth` даёт 405!).

```bash
# вход:
curl -s -X POST http://127.0.0.1:9120/auth/login/LoginLocalUser \
  -H 'Content-Type: application/json' -d '{"username":"admin","password":"..."}'
# → извлечь токен: grep '"jwt"'
# дальше: -H "Authorization: <токен>"
```

| Задача | Вызов |
|---|---|
| Список серверов | `POST /read/ListServers` |
| Список Swarm | `POST /read/ListSwarms` |
| Создать Swarm | `POST /write/CreateSwarm` |
| Создать стек | `POST /write/CreateStack` |
| Выкатить стек | `POST /execute/DeployStack` |
| Onboarding-ключ | `POST /write/CreateOnboardingKey` |

Важно: **Pangolin API и Komodo API — разные продукты с разными API** (не путать; обе
путаницы уже были).

## Полезные команды на ноде

```bash
# --- здоровье ---
docker node ls
docker ps --format '{{.Names}}\t{{.Status}}' | sort
journalctl -t db-guard -n 30 --no-pager
wg show | grep -E 'peer|latest handshake'
ip -4 addr show wg0        # 10.66.0.X + 10.66.0.99

# --- PG ---
docker exec -u postgres pg-<app> psql -U postgres -tAc "SELECT pg_is_in_recovery()"
docker exec -u postgres pg-<app> psql -U postgres -tAc \
  "SELECT application_name, client_addr, state FROM pg_stat_replication"
docker exec -u postgres pg-<app> psql -U postgres -c "SHOW primary_conninfo"  # цель стендбая
# запись через VIP:
. /etc/db/secrets/<app>.env
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" pg-<app> psql -h 10.66.0.99 -p 5432 -U postgres

# --- Mongo (ТОЛЬКО отдельным контейнером!) ---
docker run --rm --network host mongo:7 mongosh \
  "mongodb://10.66.0.99:27017/?replicaSet=rs_komodo" --quiet --eval 'rs.status().members.map(m=>m.name+":"+m.stateStr)'

# --- метки Swarm ---
docker node inspect <swarm-имя> --format '{{json .Spec.Labels}}'

# --- сеть ---
nmap -Pn <ip>               # сверка с таблицей портов (с соседней ноды)
iptables -L DOCKER-USER -n --line-numbers
ufw status verbose

# --- Pangolin ---
cd /opt/pangolin && docker compose up -d --force-recreate gerbil traefik   # только вместе!
/usr/local/bin/pangolin-wildcard-repair.sh <ip>
```

## Полезные команды с рабочей машины

```bash
# тест ресурса по каждому IP:
curl -sk --resolve <имя>:443:<ip> https://<имя>/ -o /dev/null -w "via <ip>: %{http_code}\n"
# сертификат:
echo | openssl s_client -connect <имя>:443 -servername <имя> 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# DNS:
dig +short <имя>            # nslookup <имя>
# SSH (стенд): порт 2222, ключ ~/.ssh/vps_ed25519
ssh -p 2222 root@<ip>
```

## curl exit-коды (диагностика)

| Код | Значение |
|---|---|
| 0 | соединение и запрос успешны |
| 7 | connection refused (порт закрыт/служба мертва) |
| 28 | timeout (режут/не отвечает — фильтр, туннель, фенс) |
| 60 | сертификат (для диагностики: -k) |

## Маскировка секретов перед показом

```bash
<команда> 2>&1 | sed "s/[A-Za-z0-9_-]\{20,\}/СКРЫТ/g"
```

---
*Обновлено: 2026-11-12.*
