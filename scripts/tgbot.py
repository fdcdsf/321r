#!/usr/bin/env python3
# 321r Telegram bot: управление + алерты (дизайн: V1/21 §3).
# Только stdlib (налог на память ~20-30 МБ). Команды принимаются ТОЛЬКО от TG_CHAT_ID.
# Токен — /etc/db/secrets/telegram.env (в git не попадает). v1: команды чтения;
# опасные операции с кнопками подтверждения — следующая итерация (8.5).
import json, re, shlex, subprocess, time, urllib.parse, urllib.request

ENV = "/etc/db/secrets/telegram.env"


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


env = load_env(ENV)
TOKEN = env["TG_BOT_TOKEN"]
ALLOWED = {s.strip() for s in env.get("TG_CHAT_ID", "").split(",") if s.strip()}
API = "https://api.telegram.org/bot" + TOKEN
# Профиль ноды (a/b/c) — из nodes.map; fallback — короткое hostname
NODE = (subprocess.run("awk -v s=$(hostname) '$3==s{print $1}' /etc/db/nodes.map",
                       shell=True, capture_output=True, text=True).stdout.strip()
        or subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip().split(".")[0])


def log(msg):
    print(msg, flush=True)  # уходит в journald (stdout сервиса)


def call(method, timeout=60, **params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(API + "/" + method, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def send(chat_id, text):
    try:
        call("sendMessage", chat_id=chat_id, text=text)
    except Exception as e:
        log("tgbot: ошибка отправки: %s" % e)


def sh(cmd, timeout=15):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as e:
        return "(ошибка: %s)" % e


def cluster_nodes():
    """Пары (name, ip) из /etc/db/cluster.yml (единый манифест кластера, V1/21 §4)."""
    nodes = []
    try:
        with open("/etc/db/cluster.yml") as f:
            for line in f:
                m = re.search(r"name:\s*([a-z0-9_-]+).*?ip:\s*([0-9.]+)", line)
                if m:
                    nodes.append((m.group(1), m.group(2)))
    except FileNotFoundError:
        pass
    return nodes


REMOTE = (
    "uptime | sed 's/.*load/load/'; "
    "free -m | awk '/Mem:/{print $7 \"MB свободно\"}'; "
    "docker ps --filter status=running -q | wc -l | sed 's/$/ контейнеров/'; "
    "docker exec -u postgres pg-pangolin psql -U postgres -tAc "
    "\"SELECT CASE WHEN pg_is_in_recovery() THEN 'pg:standby' ELSE 'pg:PRIMARY' END\" 2>/dev/null || echo 'pg:-'; "
    "test -f /var/lib/pgbackup/last_ok && echo \"бэкап $(( ($(date +%s) - $(stat -c %Y /var/lib/pgbackup/last_ok)) / 3600 ))ч назад\" "
    "|| echo 'бэкап: НИКОГДА'"
)


def node_status(name, ip):
    out = sh("ssh -n -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@%s %s" % (ip, shlex.quote(REMOTE)), timeout=12)
    body = "; ".join(l for l in out.splitlines() if l.strip()) or "нет ответа"
    return "%s (%s): %s" % (name, ip, body)


def cmd_status(chat_id):
    nodes = cluster_nodes()
    if not nodes:
        send(chat_id, "Не найден /etc/db/cluster.yml")
        return
    lines = ["321r · статус кластера:", node_status(NODE + " (я)", "localhost")]
    for name, ip in nodes:
        if name == NODE:
            continue
        lines.append(node_status(name, ip))
    send(chat_id, "\n".join(lines))


def handle(chat_id, text):
    log("tgbot: команда %r от %s" % (text, chat_id))
    cmd = text.split()[0].split("@")[0].lstrip("/") if text else ""
    if cmd in ("start", "help"):
        send(chat_id, "321r бот управления.\nКоманды:\n/status — статус кластера\n"
                      "/export — выгрузить бэкапы на физический носитель\n/ping — проверка связи")
    elif cmd == "ping":
        send(chat_id, "pong · нода " + NODE)
    elif cmd == "status":
        cmd_status(chat_id)
    elif cmd == "export":
        send(chat_id, "Запускаю выгрузку бэкапов со всех нод — файлы придут сюда, сохраните на диск.")
        for name, ip in cluster_nodes():
            sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'nohup /usr/local/bin/tg-export.sh >/dev/null 2>&1 &'" % ip, timeout=10)
        log("tgbot: выгрузка запущена на всех нодах")
    elif cmd:
        send(chat_id, "Неизвестная команда. /help")


def main():
    offset = 0
    log("tgbot: старт на ноде " + NODE)
    try:
        call("sendMessage", chat_id=next(iter(ALLOWED)), text="321r · бот запущен на ноде " + NODE)
    except Exception:
        pass
    while True:
        try:
            r = call("getUpdates", timeout=50, offset=offset,
                     allowed_updates=json.dumps(["message"]))
            for u in r.get("result", []):
                offset = u["update_id"] + 1
                msg = u.get("message") or {}
                chat_id = str(msg.get("chat", {}).get("id", ""))
                if chat_id not in ALLOWED:
                    continue  # чужие — молча игнорируем
                handle(chat_id, (msg.get("text") or "").strip())
        except Exception:
            time.sleep(5)


if __name__ == "__main__":
    main()
