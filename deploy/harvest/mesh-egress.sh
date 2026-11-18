#!/usr/bin/env bash
# persist: SNAT mesh-трафика наружу (mtproto-egress с РФ-ноды, docs/remnawave.md)
IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
iptables -t nat -C POSTROUTING -s 10.66.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null   || iptables -t nat -A POSTROUTING -s 10.66.0.0/24 -o "$IFACE" -j MASQUERADE
