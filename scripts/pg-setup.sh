#!/usr/bin/env bash
# pg-setup.sh primary|replica — фаза 4А: общий слой PostgreSQL 17 (PLAN §«Фаза 4»).
#
#   bash pg-setup.sh primary   # VPS-2 (b, 10.66.0.2): init, роли/БД, WAL-архив, дампы
#   bash pg-setup.sh replica   # VPS-1 (a, 10.66.0.1): pg_basebackup -R со стримингом WAL
#
# Пароли генерируются СКРИПТОМ НА УЗЛЕ в /opt/postgres/.env (права 600) —
# в чат, в логи и в git не попадают. Повторный запуск идемпотентен.
#
# Схема: primary слушает 10.66.0.2:5432 (mesh), реплика — 10.66.0.1:5432.
# WAL: контейнер кладёт сегмент в /opt/postgres/walarchive (bind), хостовой cron
# каждые 5 мин scp'ом увозит его на VPS-3 (/var/lib/pgwal/vps2), ретеншн 7 дней там же.
# Дампы: хостовой cron раз в сутки → VPS-3 и VPS-1 (/var/lib/pgbackup), ретеншн 14 дней.
set -euo pipefail

ROLE="${1:-}"
[[ "$ROLE" == "primary" || "$ROLE" == "replica" ]] || { echo "usage: $0 primary|replica" >&2; exit 1; }

PG_IMAGE="postgres:17"
OPT="/opt/postgres"
PRIMARY_IP="10.66.0.2"    # b (absent-coral.play2go.cloud)
REPLICA_IP="10.66.0.1"    # a (naval-chocolate.ptr.network)
BULK_IP="10.66.0.3"       # c (debian) — приём WAL и дампов
SSHOPTS=(-p 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)

if [[ "$ROLE" == "primary" ]]; then BIND_IP="$PRIMARY_IP"; else BIND_IP="$REPLICA_IP"; fi

rand_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---------- docker + compose ----------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo ">>> docker/compose не найден — ставлю (get.docker.com)"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "ОШИБКА: docker compose недоступен" >&2; exit 1; }

# ---------- каталоги ----------
mkdir -p "$OPT/conf" "$OPT/init" "$OPT/scripts" "$OPT/walarchive" "$OPT/backups"
if [[ "$ROLE" == "replica" ]]; then
  mkdir -p /var/lib/pgbackup      # сюда прилетают дампы с primary
fi
chown -R 999:999 "$OPT/walarchive"
chmod 755 "$OPT" "$OPT/conf" "$OPT/init" "$OPT/scripts"

# ---------- пароли ----------
if [[ "$ROLE" == "primary" && ! -f "$OPT/.env" ]]; then
  umask 077
  cat > "$OPT/.env" <<EOF
POSTGRES_PASSWORD=$(rand_hex)
REPL_PASSWORD=$(rand_hex)
APP_PASSWORD=$(rand_hex)
BIND_IP=$BIND_IP
EOF
  echo ">>> сгенерирован $OPT/.env (600)"
fi
if [[ "$ROLE" == "replica" && ! -f "$OPT/.env" ]]; then
  echo ">>> тяну .env с primary ($PRIMARY_IP)"
  scp "${SSHOPTS[@]}" "root@${PRIMARY_IP}:$OPT/.env" "$OPT/.env"
fi
chmod 600 "$OPT/.env"
set -a; . "$OPT/.env"; set +a      # POSTGRES_PASSWORD, REPL_PASSWORD, APP_PASSWORD, BIND_IP

# .pgpass: реплике нужен пароль replicator'а для walreceiver'а и basebackup
umask 077
printf '%s:5432:*:replicator:%s\n' "$PRIMARY_IP" "$REPL_PASSWORD" > "$OPT/.pgpass"
chown 999:999 "$OPT/.pgpass"
chmod 600 "$OPT/.pgpass"

# ---------- pg_hba.conf (монтируется как hba_file — в образе нет host-репликации) ----------
cat > "$OPT/conf/pg_hba.conf" <<'EOF'
# local trust: docker exec -u postgres psql — без пароля (только внутри ноды)
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
# mesh — своя зона доверия, но по паролю ( scram )
host    all             all             10.66.0.0/24            scram-sha-256
host    replication     replicator      10.66.0.0/24            scram-sha-256
EOF
chmod 644 "$OPT/conf/pg_hba.conf"

# ---------- роли и БД (только на первом старте primary; реплика получит через basebackup) ----------
cat > "$OPT/init/01-roles.sql" <<EOF
CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '${REPL_PASSWORD}';
CREATE ROLE pangolin   WITH LOGIN PASSWORD '${APP_PASSWORD}';
CREATE DATABASE pangolin OWNER pangolin;
EOF
chmod 644 "$OPT/init/01-roles.sql"

# ---------- archive_command внутри контейнера (ssh в образе нет → кладём локально) ----------
cat > "$OPT/scripts/container-archive.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src="$1"; name="$2"
dst=/var/lib/pgwal/incoming
tmp="$dst/.tmp.$$"
cp "$src" "$tmp"
mv "$tmp" "$dst/$name"          # атомарно: хостовой cron видит только цельные сегменты
EOF
chmod 755 "$OPT/scripts/container-archive.sh"

# ---------- compose ----------
cat > "$OPT/compose.yml" <<'EOF'
name: pg
services:
  postgres:
    image: postgres:17
    container_name: pg
    restart: unless-stopped
    command:
      - postgres
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - wal_level=replica
      - -c
      - max_wal_senders=10
      - -c
      - wal_keep_size=256MB
      - -c
      - archive_mode=on
      - -c
      - archive_command=/usr/local/bin/container-archive.sh %p %f
      - -c
      - archive_timeout=300
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      HOME: /var/lib/postgresql            # walreceiver ищет .pgpass по $HOME
      PGPASSFILE: /var/lib/postgresql/.pgpass
    ports:
      - "${BIND_IP}:5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - /opt/postgres/conf/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - /opt/postgres/scripts/container-archive.sh:/usr/local/bin/container-archive.sh:ro
      - /opt/postgres/walarchive:/var/lib/pgwal/incoming
      - /opt/postgres/init:/docker-entrypoint-initdb.d:ro
      - /opt/postgres/.pgpass:/var/lib/postgresql/.pgpass:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 6
volumes:
  pgdata:
    name: pgdata
EOF

# ---------- host-скрипты (только primary) ----------
if [[ "$ROLE" == "primary" ]]; then
  cat > "$OPT/scripts/pg-archive-push.sh" <<EOF
#!/usr/bin/env bash
# каждые 5 мин: сегменты WAL → VPS-3, ретеншн на VPS-3 — 7 дней
set -euo pipefail
SSHOPTS=(-p 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
cd "$OPT/walarchive"
shopt -s nullglob
for f in 0000*; do
  scp "\${SSHOPTS[@]}" "\$f" "root@${BULK_IP}:/var/lib/pgwal/vps2/" && rm -f "\$f"
done
ssh "\${SSHOPTS[@]}" "root@${BULK_IP}" 'find /var/lib/pgwal/vps2 -name "0000*" -mtime +7 -delete'
EOF
  chmod 755 "$OPT/scripts/pg-archive-push.sh"

  cat > "$OPT/scripts/pg-dump.sh" <<'EOF'
#!/usr/bin/env bash
# раз в сутки: pg_dump всех БД (plain+gzip) → VPS-3 и VPS-1; ретеншн там — 14 дней
set -euo pipefail
SSHOPTS=(-p 2222 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
TS=$(date +%Y%m%d-%H%M%S)
OUT=/opt/postgres/backups
mkdir -p "$OUT"
DBS=$(docker exec -u postgres pg psql -U postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate")
for db in $DBS; do
  docker exec -u postgres pg pg_dump -U postgres -d "$db" | gzip > "$OUT/$db-$TS.sql.gz"
done
for host in 10.66.0.3 10.66.0.1; do
  scp "${SSHOPTS[@]}" "$OUT"/*-"$TS".sql.gz "root@${host}:/var/lib/pgbackup/"
  ssh "${SSHOPTS[@]}" "root@${host}" 'find /var/lib/pgbackup -name "*.sql.gz" -mtime +14 -delete'
done
find "$OUT" -name "*.sql.gz" -mtime +1 -delete
EOF
  chmod 755 "$OPT/scripts/pg-dump.sh"

  cat > /etc/cron.d/pg-archive <<'EOF'
*/5 * * * * root /opt/postgres/scripts/pg-archive-push.sh >> /var/log/pg-archive.log 2>&1
EOF
  cat > /etc/cron.d/pg-dump <<'EOF'
33 3 * * * root /opt/postgres/scripts/pg-dump.sh >> /var/log/pg-dump.log 2>&1
EOF
  chmod 644 /etc/cron.d/pg-archive /etc/cron.d/pg-dump
fi

# ---------- запуск ----------
cd "$OPT"

if [[ "$ROLE" == "primary" ]]; then
  docker compose pull -q
  docker compose up -d
  echo ">>> жду готовности primary..."
  for _ in $(seq 1 60); do
    docker exec pg pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec pg pg_isready -U postgres >/dev/null 2>&1 || { echo "ОШИБКА: primary не поднялся" >&2; exit 1; }
  echo ">>> primary готов: $(docker exec -u postgres pg psql -U postgres -Atc 'SELECT version()')"
else
  # реплика: basebackup — только если volume пуст (PG_VERSION отсутствует)
  if docker run --rm -v pgdata:/d --entrypoint ls "$PG_IMAGE" /d/PG_VERSION >/dev/null 2>&1; then
    echo ">>> volume уже содержит кластер — basebackup пропускаю"
  else
    docker volume create pgdata >/dev/null
    echo ">>> подготовка volume (chown 999)..."
    docker run --rm -v pgdata:/d --entrypoint chown "$PG_IMAGE" -R 999:999 /d
    echo ">>> pg_basebackup -R -X stream с $PRIMARY_IP ..."
    docker run --rm --user 999 \
      -e PGPASSFILE=/var/lib/postgresql/.pgpass \
      -v pgdata:/var/lib/postgresql/data \
      -v "$OPT/.pgpass:/var/lib/postgresql/.pgpass:ro" \
      "$PG_IMAGE" pg_basebackup -h "$PRIMARY_IP" -U replicator \
      -D /var/lib/postgresql/data -R -X stream
    echo ">>> basebackup готов"
  fi
  docker compose pull -q
  docker compose up -d
  echo ">>> жду готовности реплики..."
  for _ in $(seq 1 60); do
    docker exec pg pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec pg pg_isready -U postgres >/dev/null 2>&1 || { echo "ОШИБКА: реплика не поднялась" >&2; exit 1; }
  echo ">>> реплика готова: recovery=$(docker exec -u postgres pg psql -U postgres -Atc 'SELECT pg_is_in_recovery()')"
fi
