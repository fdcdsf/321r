#!/usr/bin/env python3
# 321r Telegram bot v3 — панель кластера на кнопках (дизайн V1/21 §3).
# Вложенные меню, живой экран (editMessageText), подтверждения опасных действий.
# Только stdlib (~20-30 МБ). Команды/кнопки — только от TG_CHAT_ID. Секреты — /etc/db/secrets/.
#
# Локальная проверка рендера: tgbot.py --screen status|services|...
import json, re, shlex, subprocess, sys, time, urllib.parse, urllib.request

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
NODE = (subprocess.run("awk -v s=$(hostname) '$3==s{print $1}' /etc/db/nodes.map",
                       shell=True, capture_output=True, text=True).stdout.strip()
        or subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip().split(".")[0])


def log(msg):
    print(msg, flush=True)


def call(method, timeout=60, **params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(API + "/" + method, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def sh(cmd, timeout=25):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as e:
        return "(ошибка: %s)" % e


def cluster_nodes():
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


def node_ip(name):
    return dict(cluster_nodes()).get(name, "")


def on_nodes(cmd, timeout=30):
    out = []
    for name, ip in cluster_nodes():
        body = sh("ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=5 root@%s %s" % (ip, shlex.quote(cmd)), timeout=timeout)
        out.append((name, body or "нет ответа"))
    return out


def containers_on(name, ip):
    return [c for c in sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'docker ps --format {{.Names}}'" % ip, timeout=10).splitlines() if c.strip()]


def btn(text, data):
    return {"text": text, "callback_data": data}


# ---------------- реестр приложений (карточки в боте) ----------------
APPS = {
    "pangolin": {
        "title": "🧩 Pangolin — кластер туннелей",
        "desc": "Ингресс 443 (gerbil), дашборд, сайты-агенты, ресурсы",
        "urls": ["https://pangolin.321r.ru/"],
        "db": "pangolin",
        "ct": [("pangolin", "панель"), ("pg-pangolin", "БД postgres"), ("gerbil", "вход 443"), ("traefik", "роутинг")],
        "units": [("pangolin-site", "агент сайта")],
    },
    "remnawave": {
        "title": "🧩 Remnawave — VPN и маскировка",
        "desc": "Панель VPN, подписки, Xray-ноды, маски vpn-*/tg, Reality :2087",
        "urls": ["https://rem.321r.ru/", "https://vpn-a.321r.ru/", "https://vpn-b.321r.ru/",
                 "https://vpn-c.321r.ru/", "https://tg.321r.ru/"],
        "db": "remnawave",
        "ct": [("remnawave", "панель"), ("remnawave-subscription-page", "страница подписок"),
               ("pg-remnawave", "БД postgres"), ("remnanode", "xray-нода")],
        "units": [],
    },
    "komodo": {
        "title": "🧩 Komodo — управление стеками",
        "desc": "Core (swarm), агенты periphery, БД mongo (RS + арбитр)",
        "urls": ["https://komodo.321r.ru/"],
        "db": "komodo",
        "ct": [("mongod-komodo", "БД mongo")],
        "units": [("periphery", "агент")],
    },
    "mtproto": {
        "title": "🧩 Telegram-прокси (mtproto)",
        "desc": "Маска tg.321r.ru; egress из РФ — через mesh-шлюз на b",
        "urls": ["https://tg.321r.ru/"],
        "db": None,
        "ct": [],
        "units": [("mtproto-proxy", "прокси")],
    },
}


def grid(rows):
    return [[btn(t, d) for t, d in row] for row in rows]


BACK = ("◀ В меню", "m:main")

# ---------------- экраны: (текст, кнопки) ----------------

def scr_main():
    return ("321r · панель кластера\nНажимайте разделы — экран обновляется на месте.",
            grid([[("📊 Статус", "m:status"), ("🟢 Сервисы", "m:services")],
                  [("🧩 Приложения", "m:apps"), ("💾 Бэкапы", "m:backup")],
                  [("🗄 Базы данных", "m:db"), ("🖥 Серверы", "m:srv")],
                  [("📜 Логи", "m:logs"), ("⚙ Действия", "m:act")],
                  [("ℹ Помощь", "m:help")]]))


def scr_status(_=""):
    lines = ["📊 Статус кластера", ""]
    for name, body in on_nodes("/usr/local/bin/tg-info.sh status"):
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in body.splitlines())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "m:status")], [BACK]]))


def scr_services(_=""):
    checks = [("панель Pangolin", "https://pangolin.321r.ru/"), ("панель Remnawave", "https://rem.321r.ru/"),
              ("комодо", "https://komodo.321r.ru/"), ("маска vpn-a", "https://vpn-a.321r.ru/"),
              ("маска vpn-b", "https://vpn-b.321r.ru/"), ("маска vpn-c", "https://vpn-c.321r.ru/"),
              ("маска tg", "https://tg.321r.ru/")]
    lines = ["🟢 Внешние точки", ""]
    for title, url in checks:
        code = sh("curl -sk -o /dev/null -w %%{http_code} --max-time 8 %s" % shlex.quote(url), timeout=12)
        lines.append("%s %s — %s" % ("✅" if code == "200" else "⚠", title, code or "нет ответа"))
    lines.append("")
    lines.append("Локально по нодам:")
    for name, body in on_nodes("/usr/local/bin/tg-info.sh services"):
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in body.splitlines())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "m:services")], [BACK]]))


def scr_backup(_=""):
    lines = ["💾 Бэкапы (правило 3-2-1)", ""]
    for name, body in on_nodes("/usr/local/bin/tg-info.sh backup"):
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in body.splitlines())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "m:backup")],
                  [("🚀 Прогнать сейчас", "ask:backup"), ("🧪 Верификация", "ask:verify")],
                  [("📦 Выгрузить на диск", "ask:export")], [BACK]]))


def scr_db(_=""):
    lines = ["🗄 Базы данных", ""]
    for name, body in on_nodes("/usr/local/bin/tg-info.sh db"):
        lines.append("【%s】\n%s" % (name, body))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "m:db")], [BACK]]))


def scr_srv(_=""):
    rows = [[(n, "m:srv:" + n) for n, _ in cluster_nodes()]]
    rows.append([BACK])
    return ("🖥 Серверы — выберите ноду:", grid(rows))


def scr_srv_node(arg):
    return ("🖥 Нода %s — действия:" % arg,
            grid([[("📊 Статус", "m:sn:" + arg + ":status"), ("💿 Диски", "m:sn:" + arg + ":disk")],
                  [("🗄 Базы", "m:sn:" + arg + ":db"), ("📜 Логи", "m:sn:" + arg + ":logs")],
                  [("📦 Контейнеры", "m:ct:" + arg)],
                  [("◀ Серверы", "m:srv"), BACK]]))


def scr_srv_node_info(arg):
    name, sub = arg.split(":", 1)
    body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s '/usr/local/bin/tg-info.sh %s'" % (node_ip(name), shlex.quote(sub)), timeout=40)
    return ("🖥 %s · %s\n%s" % (name, sub, (body or "нет ответа"))[:3900],
            grid([[("🔄 Обновить", "m:sn:" + arg)], [("◀ Назад", "m:srv:" + name)]]))


def scr_ct(arg):
    ip = node_ip(arg)
    cts = containers_on(arg, ip)
    rows = []
    for i in range(0, min(len(cts), 12), 2):
        rows.append([(cts[i], "ask:restart:" + arg + ":" + cts[i])] +
                    ([(cts[i + 1], "ask:restart:" + arg + ":" + cts[i + 1])] if i + 1 < len(cts) else []))
    rows.append([("◀ Назад", "m:srv:" + arg)])
    return ("📦 Контейнеры на %s — нажмите для перезапуска:" % arg, grid(rows))


def scr_logs(_=""):
    rows = [[(n, "m:lg:" + n) for n, _ in cluster_nodes()]]
    rows.append([BACK])
    return ("📜 Логи — выберите ноду:", grid(rows))


def scr_logs_node(arg):
    cts = containers_on(arg, node_ip(arg))
    picks = [("db-guard", "m:lt:" + arg + ":db-guard"), ("backup-321r", "m:lt:" + arg + ":backup321r"),
             ("система (за час)", "m:lt:" + arg + ":syslog")]
    rows = [[t, d] for t, d in picks]
    for i in range(0, min(len(cts), 10), 2):
        rows.append([(cts[i], "m:lt:" + arg + ":" + cts[i])] +
                    ([(cts[i + 1], "m:lt:" + arg + ":" + cts[i + 1])] if i + 1 < len(cts) else []))
    rows.append([("◀ Назад", "m:logs"), BACK])
    return ("📜 Логи на %s — что показать?" % arg, grid(rows))


def scr_lt(arg):
    name, what = arg.split(":", 1)
    ip = node_ip(name)
    if what == "syslog":
        body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'journalctl --since -1h --no-pager | tail -20'" % ip, timeout=25)
    elif what == "backup321r":
        body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'tail -20 /var/log/backup321r.log 2>/dev/null'" % ip, timeout=25)
    elif what == "db-guard":
        body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'journalctl -t db-guard --since -2h --no-pager | tail -20'" % ip, timeout=25)
    else:
        body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'docker logs --tail 20 %s 2>&1'" % (ip, shlex.quote(what)), timeout=25)
    return ("📜 %s · %s\n%s" % (name, what, (body or "пусто"))[:3900],
            grid([[("🔄 Обновить", "m:lt:" + arg)], [("◀ Назад", "m:lg:" + name)]]))


def scr_act(_=""):
    return ("⚙ Действия (опасные — с подтверждением):",
            grid([[("🚀 Бэкап сейчас", "ask:backup")],
                  [("🧪 Верификация восстановления", "ask:verify")],
                  [("📦 Выгрузка на физ. диск", "ask:export")],
                  [("⚠ АВАРИЙНЫЙ РЕЖИМ", "ask:survival")], [BACK]]))


def scr_ask(arg):
    titles = {"backup": "Прогнать бэкап на всех нодах?",
              "verify": "Запустить верификацию восстановления (несколько минут)?",
              "export": "Выгрузить бэкапы вам в чат для записи на диск?",
              "survival": "⚠ АВАРИЙНЫЙ РЕЖИМ — потеря последних записей и риск split-brain! Поднимать выжившие инстансы принудительно?"}
    t = titles.get(arg, "Выполнить?")
    if arg.startswith("restart:"):
        _, n, c = arg.split(":", 2)
        t = "Перезапустить контейнер «%s» на ноде %s?" % (c, n)
    elif arg.startswith("member-add:"):
        _, app, n = arg.split(":", 2)
        t = "Добавить инстанс БД «%s» на ноду %s?\n(копия данных через VIP, ~1 мин; placement расширится)" % (app, n)
    elif arg.startswith("member-remove:"):
        _, app, n = arg.split(":", 2)
        t = "Убрать инстанс БД «%s» с ноды %s?\n(данные останутся на диске; первичный убрать нельзя)" % (app, n)
    elif arg.startswith("move:"):
        _, app, f, to = arg.split(":", 3)
        t = "Перенести инстанс БД «%s» с %s на %s?\n(даунтайм ~10–20 с; при переносе первичного — плановый фейловер)" % (app, f, to)
    return (t, grid([[("✅ Да, выполнить", "do:" + arg)], [("❌ Отмена", "m:main")]]))


def scr_help(_=""):
    return ("ℹ 321r · панель кластера\n\n"
            "📊 Статус — load/RAM/диски/роли БД/бэкапы по всем нодам\n"
            "🟢 Сервисы — внешние точки (панели, маски) и локальные проверки\n"
            "🧩 Приложения — карточки Pangolin / Remnawave / Komodo / mtproto:\n"
            "   где живёт, здоровье, роли БД, компоненты, логи и перезапуск\n"
            "💾 Бэкапы — правило 3-2-1: снимки, верификация, выгрузка\n"
            "🖥 Серверы — подробности по каждой ноде, контейнеры\n"
            "📜 Логи — последние события любого сервиса\n"
            "⚙ Действия — бэкап/верификация/выгрузка/аварийный режим\n\n"
            "Алерты (фейловеры, бэкапы, дозор) приходят сюда сами.\n"
            "Текстовые команды тоже работают: /status /backup /logs и т.д.",
            grid([[BACK]]))


def scr_apps(_=""):
    rows = [[(APPS[k]["title"].split("—")[0].strip(), "m:app:" + k) for k in list(APPS)[:2]],
            [(APPS[k]["title"].split("—")[0].strip(), "m:app:" + k) for k in list(APPS)[2:]]]
    rows.append([BACK])
    return ("🧩 Приложения — выберите карточку:", grid(rows))


def app_components(app, node, ip):
    """Состояние контейнеров/юнитов приложения на ноде одной командой."""
    a = APPS[app]
    parts = []
    for ct, _lbl in a["ct"]:
        parts.append(ct)
    cmd = ""
    if parts:
        cmd += "for c in %s; do printf '%%s=%%s ' $c $(docker inspect -f '{{.State.Status}}' $c 2>/dev/null || echo нет); done; " % " ".join(parts)
    if a["units"]:
        cmd += "for u in %s; do printf '%%s=%%s ' $u $(systemctl is-active $u 2>/dev/null || echo -); done" % " ".join(u for u, _ in a["units"])
    return sh("ssh -n -p 2222 -o BatchMode=yes root@%s %s" % (ip, shlex.quote(cmd.strip())), timeout=12)


def scr_app(arg):
    a = APPS.get(arg)
    if not a:
        return scr_apps()
    lines = [a["title"], a["desc"], "", "Внешние точки:"]
    for url in a["urls"]:
        code = sh("curl -sk -o /dev/null -w %%{http_code} --max-time 8 %s" % shlex.quote(url), timeout=12)
        lines.append("%s %s — %s" % ("✅" if code == "200" else "⚠", url.replace("https://", ""), code or "нет ответа"))
    lines.append("")
    lines.append("Ноды и компоненты:")
    for name, ip in cluster_nodes():
        comp = app_components(arg, name, ip) or "нет ответа"
        db = ""
        if a["db"]:
            db = sh("ssh -n -p 2222 -o BatchMode=yes root@%s '/usr/local/bin/tg-info.sh app %s'" % (ip, shlex.quote(a["db"])), timeout=20)
        lines.append("【%s】%s%s" % (name, (" " + db) if db else "", (" · " + comp) if comp else ""))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "m:app:" + arg)],
                  [("🧩 Инстансы БД", "m:inst:" + arg)],
                  [("📜 Логи компонентов", "m:appc:" + arg), ("⚙ Перезапуск", "m:appr:" + arg)],
                  [("🧩 Приложения", "m:apps"), BACK]]))


def inst_state(app):
    """[(нода, состояние)] + члены placement для БД-группы приложения.
    Источник правды о занятости — placement (остаточные данные после переноса не считаются)."""
    out, placement_raw = [], ""
    for name, ip in cluster_nodes():
        body = sh("ssh -n -p 2222 -o BatchMode=yes root@%s '/usr/local/bin/tg-info.sh app %s 2>/dev/null; sed -n \"s/^placement: *//p\" /etc/db/apps.d/%s.yaml 2>/dev/null'" % (ip, shlex.quote(app), shlex.quote(app)), timeout=20)
        lines = [l.strip() for l in body.splitlines() if l.strip()]
        pl = [l for l in lines if l.startswith("[")]
        if pl:
            placement_raw = pl[-1]
        state = "; ".join(l for l in lines if not l.startswith("["))
        out.append((name, state or ""))
    placement = placement_raw.split("#")[0].strip().rstrip()
    members = [x.strip() for x in placement.strip("[]").split(",") if x.strip()]
    return placement, members, out


def scr_inst(arg):
    placement, members, states = inst_state(arg)
    lines = ["🧩 Инстансы БД «%s» — placement %s" % (arg, placement or "?"), ""]
    for name, state in states:
        if name in members:
            lines.append("【%s】 %s" % (name, state or "в группе"))
        else:
            note = "свободна"
            if "остановлен" in state:
                note += " (лежат старые данные — будут перезалиты)"
            lines.append("【%s】 %s" % (name, note))
    rows = []
    if len(members) > 1:
        rows.append([("↔ Перенести инстанс", "m:instm:" + arg)])
    rows.append([("➕ Добавить инстанс", "m:instd:" + arg), ("➖ Убрать инстанс", "m:instr:" + arg)])
    rows.append([("🔄 Обновить", "m:inst:" + arg), ("◀ Назад", "m:app:" + arg)])
    return ("\n".join(lines)[:3900], grid(rows))


def scr_instd(arg):
    _, members, states = inst_state(arg)
    free = [n for n, _ in states if n not in members]
    rows = [[(f, "ask:member-add:" + arg + ":" + f) for f in free[i:i+2]] for i in range(0, len(free), 2)]
    if not rows:
        return ("➕ Добавить инстанс %s: свободных нод нет (все заняты)." % arg,
                grid([[("◀ Назад", "m:inst:" + arg)]]))
    rows.append([("◀ Назад", "m:inst:" + arg)])
    return ("➕ Добавить инстанс БД «%s» — на какую ноду? (копия данных через VIP)" % arg, grid(rows))


def scr_instr(arg):
    _, members, _states = inst_state(arg)
    rows = [[(h, "ask:member-remove:" + arg + ":" + h) for h in members[i:i+2]] for i in range(0, len(members), 2)]
    rows.append([("◀ Назад", "m:inst:" + arg)])
    return ("➖ Убрать инстанс БД «%s» — с какой ноды?\n(первичный убрать нельзя — сначала перенос; данные остаются на диске)" % arg, grid(rows))


def scr_instm(arg):
    app, frm = arg.split(":", 1)
    _, members, states = inst_state(app)
    free = [n for n, _ in states if n not in members and n != frm]
    rows = [[(f, "ask:move:" + app + ":" + frm + ":" + f) for f in free[i:i+2]] for i in range(0, len(free), 2)]
    if not rows:
        return ("↔ Перенести %s с %s: целевых нод нет." % (app, frm), grid([[("◀ Назад", "m:inst:" + app)]]))
    rows.append([("◀ Назад", "m:inst:" + app)])
    return ("↔ Перенести инстанс «%s» с %s — на какую ноду? (даунтайм ~10–20 с)" % (app, frm), grid(rows))


def scr_appc(arg):
    """Логи компонентов приложения: выбор компонента."""
    a = APPS.get(arg)
    if not a:
        return scr_apps()
    rows = []
    picks = []
    for ct, lbl in a["ct"]:
        for name, ip in cluster_nodes():
            st = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'docker inspect -f {{.State.Status}} %s 2>/dev/null'" % (ip, shlex.quote(ct)), timeout=8)
            if st:
                picks.append(("%s @%s" % (lbl, name), "m:lt:" + name + ":" + ct))
    for u, lbl in a["units"]:
        for name, ip in cluster_nodes():
            st = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'systemctl is-active %s 2>/dev/null'" % (ip, shlex.quote(u)), timeout=8)
            if st and st != "inactive":
                picks.append(("%s @%s" % (lbl, name), "m:lt:" + name + ":" + u))
    for i in range(0, min(len(picks), 12), 2):
        rows.append([picks[i]] + ([picks[i + 1]] if i + 1 < len(picks) else []))
    rows.append([("◀ Назад", "m:app:" + arg)])
    return ("📜 Логи — выберите компонент %s:" % a["title"].split("—")[0].strip(), grid(rows))


def scr_appr(arg):
    """Перезапуск компонентов приложения: выбор (кнопка → подтверждение)."""
    a = APPS.get(arg)
    if not a:
        return scr_apps()
    rows = []
    picks = []
    for ct, lbl in a["ct"]:
        for name, ip in cluster_nodes():
            st = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'docker inspect -f {{.State.Status}} %s 2>/dev/null'" % (ip, shlex.quote(ct)), timeout=8)
            if st:
                picks.append(("%s @%s" % (lbl, name), "ask:restart:" + name + ":" + ct))
    for i in range(0, min(len(picks), 12), 2):
        rows.append([picks[i]] + ([picks[i + 1]] if i + 1 < len(picks) else []))
    rows.append([("◀ Назад", "m:app:" + arg)])
    return ("⚙ Перезапуск — выберите компонент %s (будет подтверждение):" % a["title"].split("—")[0].strip(), grid(rows))


SCREENS = {"m:main": scr_main, "m:status": scr_status, "m:services": scr_services,
           "m:backup": scr_backup, "m:db": scr_db, "m:srv": scr_srv, "m:logs": scr_logs,
           "m:act": scr_act, "m:help": scr_help, "m:apps": scr_apps}


def render(data):
    """callback_data → (текст, кнопки)."""
    if data.startswith("m:instm:"):
        return scr_instm(data[8:])
    if data.startswith("m:instd:"):
        return scr_instd(data[8:])
    if data.startswith("m:instr:"):
        return scr_instr(data[8:])
    if data.startswith("m:inst:"):
        return scr_inst(data[7:])
    if data.startswith("m:app:"):
        return scr_app(data[6:])
    if data.startswith("m:appc:"):
        return scr_appc(data[7:])
    if data.startswith("m:appr:"):
        return scr_appr(data[7:])
    if data.startswith("m:srv:"):
        return scr_srv_node(data[6:])
    if data.startswith("m:sn:"):
        return scr_srv_node_info(data[5:])
    if data.startswith("m:ct:"):
        return scr_ct(data[5:])
    if data.startswith("m:lg:"):
        return scr_logs_node(data[5:])
    if data.startswith("m:lt:"):
        return scr_lt(data[5:])
    if data.startswith("ask:"):
        return scr_ask(data[4:])
    f = SCREENS.get(data)
    return f() if f else scr_main()


# ---------------- действия ----------------

def do_action(chat_id, action, msg_id=None):
    def finish(text):
        try:
            call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text[:3900],
                 reply_markup=json.dumps({"inline_keyboard": grid([[("◀ В меню", "m:main")]])}))
        except Exception:
            pass

    if action.startswith("restart:"):
        _, n, c = action.split(":", 2)
        out = sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'docker restart %s'" % (node_ip(n), shlex.quote(c)), timeout=60)
        log("tgbot: restart %s@%s -> %s" % (c, n, out))
        finish("✅ Контейнер «%s» на %s перезапущен.%s" % (c, n, (" (" + out + ")") if out else ""))
        return
    if action.startswith("member-add:"):
        _, app, n = action.split(":", 2)
        out = sh("/usr/local/bin/app-member.sh add %s %s 2>&1 | tail -7" % (shlex.quote(app), shlex.quote(n)), timeout=240)
        log("tgbot: member-add %s@%s: %s" % (app, n, out.replace("\n", " | ")))
        finish("➕ Инстанс «%s» → %s\n%s" % (app, n, out[:1600]))
        return
    if action.startswith("member-remove:"):
        _, app, n = action.split(":", 2)
        out = sh("/usr/local/bin/app-member.sh remove %s %s 2>&1 | tail -6" % (shlex.quote(app), shlex.quote(n)), timeout=120)
        log("tgbot: member-remove %s@%s: %s" % (app, n, out.replace("\n", " | ")))
        finish("➖ Инстанс «%s» с %s\n%s" % (app, n, out[:1600]))
        return
    if action.startswith("move:"):
        _, app, f, to = action.split(":", 3)
        out = sh("/usr/local/bin/app-move.sh %s %s %s 2>&1 | tail -9" % (shlex.quote(app), shlex.quote(f), shlex.quote(to)), timeout=300)
        log("tgbot: move %s %s->%s: %s" % (app, f, to, out.replace("\n", " | ")))
        finish("↔ Перенос «%s»: %s → %s\n%s" % (app, f, to, out[:1600]))
        return
    if action == "backup":
        for n, ip in cluster_nodes():
            sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'nohup /usr/local/bin/backup-321r.sh >/dev/null 2>&1 &'" % ip, timeout=10)
        finish("🚀 Бэкап запущен на всех нодах. Итоги придут алертами (обычно 2–4 минуты).")
    elif action == "verify":
        for n, ip in cluster_nodes():
            sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'nohup /usr/local/bin/backup-verify.sh >/dev/null 2>&1 &'" % ip, timeout=10)
        finish("🧪 Верификация восстановления запущена (несколько минут). Итог придёт алертом: «ВСЁ ВОССТАНАВЛИВАЕТСЯ».")
    elif action == "export":
        for n, ip in cluster_nodes():
            sh("ssh -n -p 2222 -o BatchMode=yes root@%s 'nohup /usr/local/bin/tg-export.sh >/dev/null 2>&1 &'" % ip, timeout=10)
        finish("📦 Выгрузка запущена — файлы придут сюда сообщениями. Скопируйте их на физический диск.")
    elif action == "survival":
        for n, ip in cluster_nodes():
            out = sh("ssh -n -p 2222 -o BatchMode=yes root@%s /usr/local/bin/survival.sh 2>&1 | tail -2" % ip, timeout=90)
            log("tgbot: survival на %s: %s" % (n, out.replace("\n", " | ")))
        finish("⚠ Аварийный режим разослан. Если первичные были живы — предохранитель ничего не тронул. Проверьте 📊 Статус.")
    else:
        finish("Неизвестное действие.")


def handle_callback(cb):
    cid, data = cb.get("id"), cb.get("data", "")
    msg = cb.get("message") or {}
    chat_id, msg_id = str(msg.get("chat", {}).get("id", "")), msg.get("message_id")
    if chat_id not in ALLOWED:
        return
    try:
        call("answerCallbackQuery", callback_query_id=cid)
    except Exception:
        pass
    log("tgbot: кнопка %r" % data)
    try:
        if data.startswith("do:"):
            do_action(chat_id, data[3:], msg_id)
            return
        text, keyboard = render(data)
        call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text[:3900],
             reply_markup=json.dumps({"inline_keyboard": keyboard}))
    except Exception as e:
        log("tgbot: ошибка экрана %r: %s" % (data, e))


def send_menu(chat_id):
    text, keyboard = scr_main()
    try:
        call("sendMessage", chat_id=chat_id, text=text, reply_markup=json.dumps({"inline_keyboard": keyboard}))
    except Exception as e:
        log("tgbot: ошибка отправки меню: %s" % e)


def handle_text(chat_id, text):
    parts = text.split()
    cmd = parts[0].split("@")[0].lstrip("/") if text else ""
    alias = {"start": "m:main", "menu": "m:main", "help": "m:help", "status": "m:status",
             "services": "m:services", "backup": "m:backup", "db": "m:db", "disk": "m:srv",
             "logs": "m:logs", "certs": "m:services"}
    if cmd == "ping":
        try:
            call("sendMessage", chat_id=chat_id, text="pong · нода " + NODE)
        except Exception:
            pass
    elif cmd == "restart" and len(parts) > 1:
        text_, kb_ = scr_ask("restart:" + NODE + ":" + parts[1])
        try:
            call("sendMessage", chat_id=chat_id, text=text_, reply_markup=json.dumps({"inline_keyboard": kb_}))
        except Exception:
            pass
    elif cmd in alias:
        if alias[cmd] == "m:main":
            send_menu(chat_id)
        else:
            t, k = render(alias[cmd])
            try:
                call("sendMessage", chat_id=chat_id, text=t, reply_markup=json.dumps({"inline_keyboard": k}))
            except Exception:
                pass
    elif cmd:
        try:
            call("sendMessage", chat_id=chat_id, text="Неизвестная команда — вот меню:",
                 reply_markup=json.dumps({"inline_keyboard": scr_main()[1]}))
        except Exception:
            pass


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--screen":
        s = sys.argv[2]
        if not (s.startswith("m:") or s.startswith("ask:") or s.startswith("do:")):
            s = "m:" + s
        t, _k = render(s)
        print(t)
        return
    offset = 0
    log("tgbot: старт на ноде " + NODE)
    for chat in ALLOWED:
        send_menu(chat)
    while True:
        try:
            r = call("getUpdates", timeout=50, offset=offset,
                     allowed_updates=json.dumps(["message", "callback_query"]))
            for u in r.get("result", []):
                offset = u["update_id"] + 1
                if "callback_query" in u:
                    handle_callback(u["callback_query"])
                    continue
                msg = u.get("message") or {}
                chat_id = str(msg.get("chat", {}).get("id", ""))
                if chat_id not in ALLOWED:
                    continue
                handle_text(chat_id, (msg.get("text") or "").strip())
        except Exception:
            time.sleep(5)


if __name__ == "__main__":
    main()
