#!/bin/bash
set -euo pipefail

# nginx and php-fpm are two containers in the same pod (or, locally, one
# compose service sharing the other's network namespace via
# `network_mode: service:`), so this is always loopback — never a Service
# DNS name. php-fpm only starts listening once its own entrypoint has
# finished setup:install/setup:upgrade/static-content:deploy, so waiting
# here keeps nginx from serving requests against a half-initialized site.
attempt=0
until (exec 3<>"/dev/tcp/127.0.0.1/9000") 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "Timed out waiting for php-fpm at 127.0.0.1:9000" >&2
    exit 1
  fi
  echo "Waiting for php-fpm at 127.0.0.1:9000 (${attempt}/60)..."
  sleep 5
done
exec 3>&- 3<&- || true

exec "$@"
