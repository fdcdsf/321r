#!/usr/bin/env python3
"""Мелкий root cron: только статусы, без секретов и постоянного процесса."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time


OUT = Path('/var/lib/zabbix-321r/snapshot.json')


def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=12, check=True).stdout
    except (subprocess.SubprocessError, OSError):
        return ''


def zabbix_ha():
    """Число активных/резервных узлов HA из общей БД Zabbix. None при недоступности."""
    env = Path('/etc/db/secrets/zabbix.env')
    if not env.is_file():
        return None
    password = ''
    for line in env.read_text(encoding='utf-8', errors='replace').splitlines():
        if line.startswith('APP_PASSWORD='):
            password = line.split('=', 1)[1].strip().strip('"').strip("'")
            break
    if not password:
        return None
    out = run('docker', 'exec', '-e', 'PGPASSWORD=' + password, 'pg-zabbix', 'psql',
              '-X', '-qAt', '-h', '10.66.0.99', '-p', '5434', '-U', 'zabbix', '-d', 'zabbix',
              '-c', 'SELECT status,count(*) FROM ha_node GROUP BY status')
    if not out.strip():
        return None
    counts = {}
    for line in out.splitlines():
        parts = line.strip().split('|')
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            counts[int(parts[0])] = int(parts[1])
    return counts


def collect():
    services = {}
    for line in run('docker', 'ps', '-a', '--format', '{{.Names}}|{{.State}}|{{.Status}}').splitlines():
        parts = line.split('|', 2)
        if len(parts) == 3:
            name, state, health = parts
            # Swarm оставляет завершённые task-контейнеры с новыми именами.
            # Это НЕ сервисы, иначе каждый rolling update вызывает ложный алерт.
            if re.search(r'\.\d+\.[a-z0-9]{8,}$', name):
                continue
            if name and len(name) < 128:
                services['docker/' + name] = int(state == 'running' and '(unhealthy)' not in health)
    for name in ('db-guard.timer', 'tgbot.service', '321r-newt.service',
                 'mtproto-proxy.service', 'certbot.timer', 'periphery.service',
                 'warp.service'):
        if Path('/etc/systemd/system/' + name).exists() or Path('/lib/systemd/system/' + name).exists():
            if run('systemctl', 'is-enabled', name).strip() not in ('enabled', 'static'):
                continue  # например, tgbot отключён на не-control нодах
            services['systemd/' + name] = int(run('systemctl', 'is-active', name).strip() == 'active')
    for path in Path('/etc/db/apps.d').glob('*.yaml'):
        name = path.stem
        if name.isalnum() and len(name) < 80:
            services['app-db/' + name] = services.get('docker/pg-' + name,
                services.get('docker/mongod-' + name, 0))
        match = re.search(r'^port:\s*(\d+)\s*$', path.read_text(), re.M)
        if match:
            try:
                with socket.create_connection(('10.66.0.99', int(match.group(1))), timeout=2):
                    services['vip/' + name] = 1
            except OSError:
                services['vip/' + name] = 0
    stamp = Path('/var/lib/pgbackup/last_ok')
    # Бэкапы запускаются по ночам; до первого полного окна на новой ноде это
    # честный 0, а не «всё нормально». Допуск 36 часов (разнос окон + задержки).
    services['backup/fresh'] = int(stamp.is_file() and time.time() - stamp.stat().st_mtime < 36 * 3600)
    # HA Zabbix: 3 = active, 0 = standby. -1 = БД/кластер недоступен (тоже тревога).
    ha = zabbix_ha()
    services['zabbix/ha-active'] = ha.get(3, 0) if ha is not None else -1
    services['zabbix/ha-standby'] = ha.get(0, 0) if ha is not None else -1
    return {'services': services}


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    fd, path = tempfile.mkstemp(prefix='.snapshot-', dir=str(OUT.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(collect(), f, separators=(',', ':'))
            f.write('\n')
        os.chmod(path, 0o644)  # здесь только имена и 0/1, без секретов
        os.replace(path, OUT)
    finally:
        if os.path.exists(path):
            os.unlink(path)


if __name__ == '__main__':
    main()
