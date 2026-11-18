#!/usr/bin/env bash
# 321r · УСТАНОВКА ОДНОЙ КОМАНДОЙ. Запуск от root на ПЕРВОМ сервере:
#
#   curl -fsSL https://raw.githubusercontent.com/fdcdsf/321r/master/install/bootstrap.sh | bash
#
# Мастер спросит всё остальное: адреса и пароли других серверов, Telegram, домен.
# Установка идёт на ВСЕ сервера одновременно. На выходе — рабочий кластер.
set -euo pipefail

REPO_TARBALL="https://github.com/fdcdsf/321r/archive/refs/heads/master.tar.gz"
TARGET="/opt/321r"

[ "$(id -u)" = 0 ] || { echo "Запускайте от root (sudo -i)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
echo "321r · подготовка установщика..."
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl tar >/dev/null 2>&1
# sshpass — разовый вход по паролям на другие серверы (чтобы заложить ключ)
apt-get install -y -qq sshpass >/dev/null 2>&1 || true

echo "321r · скачиваю установщик..."
rm -rf "$TARGET" /tmp/321r-master
curl -fsSL "$REPO_TARBALL" | tar xz -C /tmp
mv /tmp/321r-master "$TARGET"
cd "$TARGET"
chmod +x install/*.sh   # тарбол GitHub может прийти без битов выполнения

# ВАЖНО: при «curl | bash» stdin — это пайп, а не терминал (урок: мастер-вопросы
# читать не откуда). Переключаем ввод мастера на настоящий терминал пользователя.
if [ -e /dev/tty ]; then
  exec bash install/install.sh < /dev/tty
else
  exec bash install/install.sh
fi
