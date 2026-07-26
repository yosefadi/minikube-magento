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

# Optional: only wired up if MAGENTO_DRAGONFLY_HOST is set, so this image
# still works standalone (e.g. a quick local test) without a cache backend.
: "${MAGENTO_DRAGONFLY_HOST:=}"
: "${MAGENTO_DRAGONFLY_PORT:=6379}"
: "${MAGENTO_DRAGONFLY_PASSWORD:=}"

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

wait_for_tcp "$MAGENTO_DB_HOST" "$MAGENTO_DB_PORT" "MariaDB"
wait_for_tcp "$MAGENTO_OPENSEARCH_HOST" "$MAGENTO_OPENSEARCH_PORT" "OpenSearch"
if [ -n "$MAGENTO_DRAGONFLY_HOST" ]; then
  wait_for_tcp "$MAGENTO_DRAGONFLY_HOST" "$MAGENTO_DRAGONFLY_PORT" "Dragonfly"
fi

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

# There's no `bin/magento` flag for the cache/page_cache/session backends
# (unlike --db-*/--opensearch-*, which setup:install takes directly), so this
# rewrites env.php's 'cache' and 'session' arrays by hand. Runs every boot,
# not just on a fresh install, so an existing volume's env.php still gets
# pointed at Dragonfly after this image is upgraded onto a site that
# predates it — cheap and idempotent either way.
#
# backend "redis" (lowercase), not the classic "Cm_Cache_Backend_Redis" from
# stock Magento's own devdocs: this codebase's cache layer
# (lib/internal/Magento/Framework/Cache/Frontend/Adapter/SymfonyAdapterProvider.php)
# replaced the legacy Zend_Cache backend resolution with its own adapter
# type map that only recognizes a handful of literal lowercase strings
# ("redis", "valkey", "memcached", ...) — anything else falls through to its
# filesystem adapter silently, no error, no warning. Verified live: with the
# classic Cm_Cache_Backend_Redis string, cache:flush "succeeds" and var/cache
# still fills up with files instead of a single byte reaching Dragonfly.
if [ -n "$MAGENTO_DRAGONFLY_HOST" ]; then
  echo "Pointing cache, full_page cache, and sessions at Dragonfly (${MAGENTO_DRAGONFLY_HOST}:${MAGENTO_DRAGONFLY_PORT})."
  MAGENTO_DRAGONFLY_HOST="$MAGENTO_DRAGONFLY_HOST" \
  MAGENTO_DRAGONFLY_PORT="$MAGENTO_DRAGONFLY_PORT" \
  MAGENTO_DRAGONFLY_PASSWORD="$MAGENTO_DRAGONFLY_PASSWORD" \
  php -r '
    $envFile = "app/etc/env.php";
    $config = include $envFile;

    $host = getenv("MAGENTO_DRAGONFLY_HOST");
    $port = getenv("MAGENTO_DRAGONFLY_PORT");
    $password = getenv("MAGENTO_DRAGONFLY_PASSWORD");

    $redisBackend = function ($database) use ($host, $port, $password) {
        return [
            "backend" => "redis",
            "backend_options" => [
                "server" => $host,
                "port" => $port,
                "password" => $password,
                "database" => $database,
                "compress_data" => "1",
            ],
        ];
    };

    $config["cache"]["frontend"]["default"] = $redisBackend("0");
    $config["cache"]["frontend"]["page_cache"] = $redisBackend("1");

    $config["session"] = [
        "save" => "redis",
        "redis" => [
            "host" => $host,
            "port" => $port,
            "password" => $password,
            "database" => "2",
            "compression_threshold" => "2048",
            "compression_library" => "gzip",
        ],
    ];

    file_put_contents($envFile, "<?php\nreturn " . var_export($config, true) . ";\n");
  '
fi

bin/magento cache:flush

exec "$@"
