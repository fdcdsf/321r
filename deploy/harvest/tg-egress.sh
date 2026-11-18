#!/usr/bin/env bash
# persist: Telegram-DC через mesh-шлюз b (РФ блокирует прямой egress, docs/remnawave.md)
for NET in 91.108.4.0/22 91.108.8.0/22 91.108.56.0/22 149.154.160.0/20; do
  ip route replace "$NET" via 10.66.0.2 dev wg0
done
