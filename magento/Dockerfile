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
        bcmath ctype curl dom ftp gd intl mbstring \
        pdo_mysql simplexml soap sockets sodium xsl zip opcache \
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
# final: nginx + php-fpm runtime, nothing PHP-CLI-build-only left behind.
# ---------------------------------------------------------------------------
FROM base AS final

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx supervisor \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
COPY --from=builder --chown=www-data:www-data /var/www/html /var/www/html

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx-site.conf /etc/nginx/sites-enabled/default
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p var generated pub/media pub/static \
    && chown -R www-data:www-data var generated pub app/etc

EXPOSE 8080
ENTRYPOINT ["entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
