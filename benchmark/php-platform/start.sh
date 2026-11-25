#!/usr/bin/env bash
# nginx (front) + php-fpm (pool estático) para a suíte do PHP.
set -euo pipefail
PORT="${PORT:-18093}"
CONF=/tmp/bench-nginx-$PORT.conf
sed "s/listen 18093/listen $PORT/" /tmp/bench-nginx.conf > "$CONF"
/sbin/php-fpm8.3 -F -y /tmp/bench-fpm.conf &
FPM=$!
trap 'kill $FPM 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do [ -S /tmp/bench-fpm.sock ] && break; sleep 0.1; done
exec /usr/sbin/nginx -c "$CONF" -p /tmp/bench-nginx -g 'daemon off;'
