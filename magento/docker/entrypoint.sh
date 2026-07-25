#!/bin/bash
set -euo pipefail

cd /var/www/html

: "${MAGENTO_DB_HOST:?MAGENTO_DB_HOST is required}"
: "${MAGENTO_DB_NAME:=magento}"
: "${MAGENTO_DB_USER:=magento}"
: "${MAGENTO_DB_PASSWORD:?MAGENTO_DB_PASSWORD is required}"
: "${MAGENTO_DB_PORT:=3306}"

: "${MAGENTO_SEARCH_ENGINE:=opensearch}"
: "${MAGENTO_OPENSEARCH_HOST:?MAGENTO_OPENSEARCH_HOST is required}"
: "${MAGENTO_OPENSEARCH_PORT:=9200}"
: "${MAGENTO_OPENSEARCH_INDEX_PREFIX:=magento2}"

: "${MAGENTO_BASE_URL:?MAGENTO_BASE_URL is required, e.g. http://magento.local/}"
: "${MAGENTO_BACKEND_FRONTNAME:=admin}"
: "${MAGENTO_LANGUAGE:=en_US}"
: "${MAGENTO_STATIC_CONTENT_LANGUAGES:=$MAGENTO_LANGUAGE}"
: "${MAGENTO_TIMEZONE:=UTC}"
: "${MAGENTO_CURRENCY:=USD}"

: "${MAGENTO_ADMIN_FIRSTNAME:=Admin}"
: "${MAGENTO_ADMIN_LASTNAME:=User}"
: "${MAGENTO_ADMIN_EMAIL:?MAGENTO_ADMIN_EMAIL is required}"
: "${MAGENTO_ADMIN_USER:=admin}"
: "${MAGENTO_ADMIN_PASSWORD:?MAGENTO_ADMIN_PASSWORD is required}"

wait_for_tcp() {
  local host="$1" port="$2" label="$3" attempt=0
  until (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      echo "Timed out waiting for ${label} at ${host}:${port}" >&2
      exit 1
    fi
    echo "Waiting for ${label} at ${host}:${port} (${attempt}/60)..."
    sleep 5
  done
  exec 3>&- 3<&- || true
}

wait_for_tcp "$MAGENTO_DB_HOST" "$MAGENTO_DB_PORT" "MySQL"
wait_for_tcp "$MAGENTO_OPENSEARCH_HOST" "$MAGENTO_OPENSEARCH_PORT" "OpenSearch"

# Not a plain file-existence check: setup:di:compile (run at build time) writes
# its own minimal app/etc/env.php as a side effect — just a cache_types key,
# no DB connection — verified live that this made a fresh container skip
# setup:install and go straight to a setup:upgrade that has nothing to connect
# to. So this checks for a real 'db' key instead of just the file being there.
has_real_install() {
  php -r '
    $config = @include "app/etc/env.php";
    exit((is_array($config) && isset($config["db"]["connection"]["default"]["host"])) ? 0 : 1);
  '
}

if ! has_real_install; then
  echo "No real database config in app/etc/env.php — running a fresh setup:install."
  # setup:install itself may refuse to run if env.php merely exists,
  # regardless of content — remove the build-time di:compile stub first.
  rm -f app/etc/env.php
  bin/magento setup:install \
    --base-url="$MAGENTO_BASE_URL" \
    --db-host="${MAGENTO_DB_HOST}:${MAGENTO_DB_PORT}" \
    --db-name="$MAGENTO_DB_NAME" \
    --db-user="$MAGENTO_DB_USER" \
    --db-password="$MAGENTO_DB_PASSWORD" \
    --search-engine="$MAGENTO_SEARCH_ENGINE" \
    --opensearch-host="$MAGENTO_OPENSEARCH_HOST" \
    --opensearch-port="$MAGENTO_OPENSEARCH_PORT" \
    --opensearch-index-prefix="$MAGENTO_OPENSEARCH_INDEX_PREFIX" \
    --admin-firstname="$MAGENTO_ADMIN_FIRSTNAME" \
    --admin-lastname="$MAGENTO_ADMIN_LASTNAME" \
    --admin-email="$MAGENTO_ADMIN_EMAIL" \
    --admin-user="$MAGENTO_ADMIN_USER" \
    --admin-password="$MAGENTO_ADMIN_PASSWORD" \
    --backend-frontname="$MAGENTO_BACKEND_FRONTNAME" \
    --language="$MAGENTO_LANGUAGE" \
    --timezone="$MAGENTO_TIMEZONE" \
    --currency="$MAGENTO_CURRENCY" \
    --use-rewrites=1

  bin/magento deploy:mode:set production
else
  echo "app/etc/env.php already present — running setup:upgrade instead."
  bin/magento setup:upgrade --keep-generated
fi

# Deliberately not nested inside the block above: app/etc and pub/static are
# typically two separate persistent volumes (see docker-compose.yml / the
# k8s PVCs this image is meant to run under), so either can independently be
# present or missing on any given container start. Checking for both env.php
# and deployed static content separately means a container that gets env.php
# from a volume but a fresh, empty pub/static still regenerates it instead of
# serving a site with no CSS/JS. Needs a live DB: this is where the default
# website/store/store-view rows get created, and static-content:deploy fails
# with "The default website isn't defined" without them — verified this is a
# hard requirement, not something that can be baked into the image at build
# time.
if [ ! -d pub/static/frontend ] && [ ! -d pub/static/adminhtml ]; then
  echo "No deployed static content found — running static-content:deploy."
  bin/magento setup:static-content:deploy -f ${MAGENTO_STATIC_CONTENT_LANGUAGES} --jobs "$(nproc)"
fi

bin/magento cache:flush

# Everything above ran as root, and setup:install/setup:upgrade/
# static-content:deploy all create fresh files under var/, generated/, and
# pub/ as they go — those end up root-owned despite the build-time chown,
# and php-fpm's workers run as www-data. Verified live: without this,
# php-fpm can't write session files or var/log/system.log and every request
# 500s with "Permission denied".
chown -R www-data:www-data var generated pub app/etc

exec "$@"
