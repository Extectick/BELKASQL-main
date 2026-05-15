#!/usr/bin/env bash
set -euo pipefail

envsubst < /templates/haproxy.cfg > /usr/local/etc/haproxy/haproxy.cfg
envsubst < /templates/keepalived.conf > /etc/keepalived/keepalived.conf

cat > /etc/keepalived/check_haproxy.sh <<'EOF'
#!/usr/bin/env bash
pidof haproxy >/dev/null 2>&1
EOF

chmod +x /etc/keepalived/check_haproxy.sh

keepalived --dont-fork --log-console -f /etc/keepalived/keepalived.conf &

exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
