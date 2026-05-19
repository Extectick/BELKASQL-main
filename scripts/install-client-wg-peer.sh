#!/usr/bin/env bash
set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
CLOUD_PEER_KEY="${CLOUD_PEER_KEY:-eAs5p0gjhliLalB4hhJe/oswJQbe50dMqeMdisr2BHE=}"
CLOUD_PEER_ALLOWED_IP="${CLOUD_PEER_ALLOWED_IP:-10.77.0.13/32}"
CLIENT_PEER_KEY="${CLIENT_PEER_KEY:-lXXS8AhyppdnfYPEMJhB230N8aezDJdI/gowQVrnpR4=}"
CLIENT_IP="${CLIENT_IP:-10.77.0.14}"

sudo wg set "${WG_IFACE}" peer "${CLOUD_PEER_KEY}" allowed-ips "${CLOUD_PEER_ALLOWED_IP}" || true
sudo wg set "${WG_IFACE}" peer "${CLIENT_PEER_KEY}" allowed-ips "${CLIENT_IP}/32"

if ! sudo grep -q "PublicKey = ${CLIENT_PEER_KEY}" "${WG_CONF}"; then
  sudo sh -c "cat >> '${WG_CONF}'" <<EOF

[Peer]
PublicKey = ${CLIENT_PEER_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF
fi

sudo sed -i "/PublicKey = ${CLOUD_PEER_KEY//\//\\/}/{n;s#AllowedIPs = .*#AllowedIPs = ${CLOUD_PEER_ALLOWED_IP}#;}" "${WG_CONF}"
sudo wg show "${WG_IFACE}" >/dev/null
