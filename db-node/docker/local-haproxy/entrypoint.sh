#!/usr/bin/env bash
set -euo pipefail

envsubst < /templates/local-haproxy.cfg > /usr/local/etc/haproxy/haproxy.cfg

exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
