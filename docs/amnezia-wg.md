# AmneziaWG — транспорт меша 321r.ru

## Факты (проверено 2026-11-08)

- **Протокол**: AmneziaWG **3.1** (обфускация + шифрование заголовков; 2.0 «уже блокируем» по
  заявлению разработчиков Amnezia).
- **Установка на Debian 13**: официальный PPA Amnezia (Launchpad, suite focal, обновляется —
  последний публиш 12.09.2026). Пакет `amneziawg` = модуль ядра (DKMS) + утилиты.
- **Отпечаток ключа подписи PPA**: `75C9DD72C799870E310542E24166F2C257290828`
  (получен из Launchpad API, совпадает с коротким ID из документации Amnezia: 57290828).
- **Требования**: виртуализация **KVM/полная VM** (на OpenVZ/LXC модуль ядра не поставить),
  x86_64, ядро **≥ 6.7** (Debian 13 даёт 6.12 ✓), ≥512 МБ RAM.
- **Команды** (проверено установкой 2026-11-08): `/usr/bin/awg`, `/usr/bin/awg-quick`;
  **awg-quick ищет конфиги в `/etc/amnezia/amneziawg/`** (не в `/etc/wireguard/`);
  модуль ядра грузится как `amneziawg` (`modprobe amneziawg` ✓).
  Пакеты: amneziawg (meta), amneziawg-dkms (`1.0.0-0~202609061402+4569c4c`), amneziawg-tools —
  сборка PPA от 06–14.09.2026. Ключи из шага 5 лежат в `/etc/wireguard/privatekey|publickey`
  — это просто файлы, awg-quick путь к ним не важен.
- Интерфейс: **wg0**, порт **51821/udp**, адреса 10.66.0.1/2/3, пины по именам a/b/c.321r.ru.

## Установка (применяется в bootstrap-пакете)

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828" \
  | gpg --dearmor -o /etc/apt/keyrings/amnezia.gpg
echo "deb [signed-by=/etc/apt/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" \
  > /etc/apt/sources.list.d/amnezia.list
apt update && apt install -y amneziawg
dkms status   # контроль: amneziawg/<версия>, <ядро>: installed
```

Сборка DKMS — 5–15 минут. Нужны `dkms` и `linux-headers-$(uname -r)` (ставятся заранее).

## Параметры wg0.conf (выбраны и проверены 2026-11-08)

Протокол **3.1 подтверждён тестом** (модуль ядра принял HeaderProtectionKey). Симметричные
параметры **обязательно одинаковы на всех трёх нодах**:

- `HeaderProtectionKey` — **секрет кластера** (сгенерирован 2026-11-08): в git не записан,
  реальное значение лежит в `/etc/amnezia/amneziawg/wg0.conf` на любой ноде; в шаблонах
  `nodes/*/wg0.conf` — плейсхолдер `{{HEADER_KEY}}`;
- `S1–S4 = 12` — минимум для header protection, фрейминг хендшейка, совпадает на всех;
- `Jc = 4`, `Jmin = 50`, `Jmax = 1000` — junk-пакеты (отправительская сторона, размер < MTU,
  согласованность между нодами не нужна, но она у нас полная);
- `PersistentKeepalive = 25` на пирах — держит линк живым и быстро показывает смерть узла;
- **не задаём**: `RandomTrailers` (в тестах резал скорость в 85–133 раза), `DisableCookies`
  (снимает защиту от флуда хендшейков); `I1` — запасная эскалация, если DPI научится резать.

**Раскатка (2026-11-08): wg0 поднят на a/b/c — handshakes (включая РФ↔зарубеж), пинги по
10.66.0.x и :22 по mesh подтверждены на всех трёх нодах.**

Ссылки: README `github.com/amnezia-vpn/amnezia-wg` (классификация параметров server-side),
материалы установщика amneziawg-installer (Debian 13 → 3.1 из этого же PPA).

## Фолбэк

Если AmneziaWG-протокол полностью заблокируют — тот же wg0.conf поднимается обычным
WireGuard (Debian-пакет `wireguard`): параметры обфускации выкинуть, порт 51821 остаётся.
Если заблокируют IP узла — меняем A-запись (ddns), меш переподключается сам (reresolve 45 с).

## Примечания

- `systemd-detect-virt` должен выдавать `none`/`kvm` — иначе (openvz/lxc) ставить нечего.
- Официальная страница docs.amnezia.org была недоступна с нашей машины — действовали по
  данным Launchpad API, форков amnezia-wg и материалам установщика amneziawg-installer.
