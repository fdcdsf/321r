#!/usr/bin/env bash
# Продуктовый инвариант: каждой VPN-ноде только свой SNI, общий tg отдельно.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmpl="$ROOT/deploy/harvest/mask_config.yml"
for a in a b c; do
  rendered="$(sed -e "s/321r\.ru/example.com/g" -e "s/__NODE__/$a/g" \
    -e 's/172\.22\.0\.1/172.21.0.1/g' "$tmpl")"
  grep -Fq "HostSNI(\`vpn-$a.example.com\`)" <<<"$rendered"
  grep -Fq 'HostSNI(`tg.example.com`)' <<<"$rendered"
  grep -Fq '172.21.0.1:9446' <<<"$rendered"
  for other in a b c; do
    [ "$a" = "$other" ] && continue
    if grep -Fq "vpn-$other.example.com" <<<"$rendered"; then
      echo "$a: чужой SNI vpn-$other обнаружен" >&2
      exit 1
    fi
  done
done
echo 'Remnawave: локальный SNI и отдельный gateway OK'
