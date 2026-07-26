# syntax=docker/dockerfile:1
ARG PHP_VERSION=8.5
ARG MAGENTO_VERSION=2.4.9

# ---------------------------------------------------------------------------
# base: PHP + every extension Magento's composer.json requires, shared by
# both the builder and final stages so extensions are only compiled once.
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-fpm-trixie AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip zip curl \
        mariadb-client \
        libzip-dev libicu-dev libxslt1-dev libonig-dev libxml2-dev \
        libfreetype-dev libjpeg62-turbo-dev libpng-dev libsodium-dev \
        libcurl4-openssl-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath ctype curl ftp gd intl mbstring \
        pdo_mysql simplexml soap sockets sodium xsl zip \
    && rm -rf /var/lib/apt/lists/*

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-magento.ini

# ---------------------------------------------------------------------------
# builder: fetch Magento Open Source, install PHP deps, and bake the
# expensive steps (di:compile, static-content:deploy) in here rather than at
# container start — that's the whole point of building instead of running
# these against a live, resource-constrained cluster.
# ---------------------------------------------------------------------------
FROM base AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1

WORKDIR /var/www/html

# The GitHub mirror's composer.json has an empty "repositories" list — every
# magento/* module ships as source in this tree already, and third-party
# deps resolve from Packagist, so this needs no repo.magento.com auth keys.
ARG MAGENTO_VERSION
RUN curl -fsSL "https://github.com/magento/magento2/archive/refs/tags/${MAGENTO_VERSION}.tar.gz" \
    | tar xz --strip-components=1

RUN composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader

ARG INSTALL_SAMPLE_DATA=false
RUN if [ "$INSTALL_SAMPLE_DATA" = "true" ]; then \
        php bin/magento sampledata:deploy && \
        composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader; \
    fi

# module:enable populates app/etc/config.php by scanning module.xml files, and
# di:compile only reads that + declared di.xml/preferences — neither needs a
# database, so both bake in here. static-content:deploy does NOT: verified
# live that it fails with "The default website isn't defined" without a real
# website/store row, which only exists after setup:install has run against a
# database — so that step happens at first boot instead (docker/entrypoint.sh).
RUN bin/magento module:enable --all \
    && bin/magento setup:di:compile

# ---------------------------------------------------------------------------
# final-php: php-fpm only. Owns the entire install/upgrade lifecycle (needs
# DB + OpenSearch access and the PHP CLI) and runs as www-data throughout —
# no root step ever runs in this container, so nothing needs a chown fixup.
# ---------------------------------------------------------------------------
FROM base AS final-php

WORKDIR /var/www/html
COPY --from=builder --chown=www-data:www-data /var/www/html /var/www/html

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p var generated pub/media pub/static \
    && chown -R www-data:www-data var generated pub app/etc

USER www-data
EXPOSE 9000
ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]

# ---------------------------------------------------------------------------
# final-nginx: static/proxy only, no PHP interpreter in this image at all.
# Needs its own copy of the codebase (not just pub/static and pub/media)
# because nginx.conf.sample does on-disk existence checks — e.g. the PHP
# entry-point location does `try_files $uri =404;` against index.php/get.php/
# static.php before it will even proxy to php-fpm — so those files must be
# physically present here, not only on the php-fpm side.
# ---------------------------------------------------------------------------
FROM nginx:1-trixie AS final-nginx

WORKDIR /var/www/html
COPY --from=builder --chown=www-data:www-data /var/www/html /var/www/html

# The stock image's own conf.d/default.conf listens on port 80 — harmless
# as root, but our nginx.conf includes conf.d/*.conf too, and a non-root
# process can't bind a privileged port, so it must go.
RUN rm -f /etc/nginx/conf.d/default.conf
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx-site.conf /etc/nginx/sites-enabled/default
COPY docker/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
RUN chmod +x /usr/local/bin/nginx-entrypoint.sh

USER www-data
EXPOSE 8080
ENTRYPOINT ["nginx-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
