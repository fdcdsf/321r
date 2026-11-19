#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf 'NODES=("a 127.0.0.1 10.66.0.1 state")\nCONTROL=a\n' > "$tmp"
INV="$tmp" source "$(dirname "$0")/../install/lib.sh"
got="$(mtproto_link tg.321r.ru 00112233445566778899aabbccddeeff)"
want='tg://proxy?server=tg.321r.ru&port=443&secret=ee00112233445566778899aabbccddeeff74672e333231722e7275'
[ "$got" = "$want" ] || { echo 'Неверный формат FakeTLS-ссылки' >&2; exit 1; }
if mtproto_link tg.321r.ru invalid >/dev/null 2>&1; then
  echo 'Неверный секрет принят' >&2
  exit 1
fi
echo 'FakeTLS-ссылка: OK'
