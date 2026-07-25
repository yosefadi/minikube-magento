# Magento Open Source — application image

Builds a single, self-contained Magento 2 image (nginx + PHP-FPM via
`supervisord`) meant to run as-is against an already-provisioned MySQL and
OpenSearch. `composer install` and `setup:di:compile` happen at build
time — verified neither needs a database. `setup:static-content:deploy`
does **not** bake in, even though it doesn't touch application data: tried it
at build time and it fails with `The default website isn't defined`, because
website/store scope only exists after `setup:install` has run against a real
database. So it runs once at first container boot instead, right after
`setup:install` (or independently, if `pub/static` ever comes up empty on a
container that already has `app/etc/env.php` from a separate volume).

## Source

Pulled from the [`magento/magento2`](https://github.com/magento/magento2)
GitHub mirror (Open Source / Community edition), not
`composer create-project --repository-url=https://repo.magento.com/...`.
That mirror's `composer.json` has an **empty `repositories` list** — every
`magento/*` module ships as source in the tree already, and every
third-party dependency resolves from Packagist — so building this image
needs **no Magento Marketplace composer auth keys**. That only becomes
necessary for Adobe Commerce, or for installing certain paid extensions.

## Build

```bash
docker build -t magento-app:2.4.9 .

# pin a different release, PHP version, or bake in sample data:
docker build \
  --build-arg MAGENTO_VERSION=2.4.9 \
  --build-arg PHP_VERSION=8.3 \
  --build-arg INSTALL_SAMPLE_DATA=true \
  -t magento-app:2.4.9 .
```

## Run

The entrypoint (`docker/entrypoint.sh`) waits for MySQL and OpenSearch on
their TCP ports, then handles two things independently (they're typically
two separate persistent volumes, so either can be present or missing on any
given start):

- `app/etc/env.php` missing → full `setup:install` (creates the DB schema,
  default website/store, and admin user); present → `setup:upgrade` instead
  (safe to run every restart).
- `pub/static/{frontend,adminhtml}` missing → `setup:static-content:deploy`;
  present → skipped.

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `MAGENTO_BASE_URL` | yes | — | e.g. `https://shop.example.com/` |
| `MAGENTO_DB_HOST` | yes | — | |
| `MAGENTO_DB_PORT` | no | `3306` | |
| `MAGENTO_DB_NAME` | no | `magento` | |
| `MAGENTO_DB_USER` | no | `magento` | |
| `MAGENTO_DB_PASSWORD` | yes | — | |
| `MAGENTO_OPENSEARCH_HOST` | yes | — | |
| `MAGENTO_OPENSEARCH_PORT` | no | `9200` | |
| `MAGENTO_OPENSEARCH_INDEX_PREFIX` | no | `magento2` | |
| `MAGENTO_ADMIN_EMAIL` | yes | — | |
| `MAGENTO_ADMIN_PASSWORD` | yes | — | Magento enforces a complexity policy |
| `MAGENTO_ADMIN_USER` | no | `admin` | |
| `MAGENTO_ADMIN_FIRSTNAME` / `_LASTNAME` | no | `Admin` / `User` | |
| `MAGENTO_BACKEND_FRONTNAME` | no | `admin` | admin panel path |
| `MAGENTO_LANGUAGE` | no | `en_US` | passed to `setup:install --language` |
| `MAGENTO_STATIC_CONTENT_LANGUAGES` | no | `$MAGENTO_LANGUAGE` | space-separated, for `setup:static-content:deploy -f`; set if you need more than one storefront locale |
| `MAGENTO_TIMEZONE` | no | `UTC` | |
| `MAGENTO_CURRENCY` | no | `USD` | |

Listens on `8080` (unprivileged — no root required to bind it).

**`app/etc/env.php` needs a persistent volume.** Without one, every container
restart looks like a first boot, `setup:install` runs again, and it fails
outright against a database that already has Magento's tables (or worse,
silently reinstalls against a half-matching schema). `pub/static` should be
persistent too — not required for correctness the way `env.php` is (the
entrypoint just redeploys it if missing), but without it every restart pays
the static-content:deploy cost again for no reason. Same goes for
`pub/media` if you want uploaded product images/etc. to survive a restart.
`docker-compose.yml` here mounts all three as named volumes — carry that
through to whatever Kubernetes manifests end up using this image (PVCs for
at least `app/etc` and `pub/static`).

## Local smoke test

```bash
docker compose up --build
# first boot runs the full installer — watch the logs
docker compose logs -f magento
```

Then hit `http://localhost:8080/`. Admin panel is at
`http://localhost:8080/<MAGENTO_BACKEND_FRONTNAME>` (default `admin`).

### MariaDB and OpenSearch requirements found by actually running this

Both surfaced as real failures during testing, not theoretical — already
applied in `docker-compose.yml` here, but carry them into whatever actually
provisions these two services elsewhere (e.g. the k8s manifests this image
eventually runs under):

- **MariaDB 12.3** is used as the database (recommended by Adobe for
  Magento 2.4.9). Unlike MySQL 8, MariaDB does not require the
  `log_bin_trust_function_creators` workaround for trigger creation.
- **OpenSearch 2.12+ requires `OPENSEARCH_INITIAL_ADMIN_PASSWORD`** to be set
  even with `plugins.security.disabled=true` — the security plugin's demo
  installer checks for it before OpenSearch itself even starts, regardless
  of whether security ends up disabled once it's running.

## Known limitations / follow-ups

- Cron (`bin/magento cron:run`) isn't wired up — no scheduled indexing,
  no email queue processing. Needs a sidecar/CronJob running the same image
  with `crontab` populated by `bin/magento cron:install`, sharing the same
  `app/code` and DB.
- No Redis — cache/session/full-page-cache all default to the filesystem
  and MariaDB. Fine for a single replica; add Redis and the corresponding
  `env.php` cache backends before scaling to more than one pod.
- Everything in the container runs as `root` (nginx master + php-fpm master
  both start as root, workers drop to `www-data`) — standard for a dev
  image, but worth hardening (non-root, read-only root filesystem) before
  this goes anywhere more exposed than a dev/demo cluster.
