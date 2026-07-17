FROM php:8.1-fpm-alpine

LABEL maintainer="v2board-docker"

ARG APP_DIR=/var/www/v2board

# Runtime deps (kept). Use the non-`-dev` library packages so the compiled
# .so extensions can link their shared libs at run time.
RUN apk add --no-cache \
        nginx \
        supervisor \
        mariadb-client \
        curl \
        fcgi \
        libzip \
        libpng \
        libjpeg-turbo \
        freetype \
        libxml2 \
        oniguruma \
    # Build deps for docker-php-ext-install + pecl. pecl needs phpize -> autoconf,
    # which docker-php-ext-install does NOT retain (it purges its own temp
    # .phpize-deps-configure). Bundle all build-only deps in a virtual package
    # and delete them after compilation to keep the image small.
    && apk add --no-cache --virtual .php-build-deps \
        $PHPIZE_DEPS \
        libzip-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        libxml2-dev \
        oniguruma-dev \
        linux-headers \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath gd pdo_mysql mysqli zip opcache pcntl soap \
    && pecl install igbinary redis \
    && docker-php-ext-enable igbinary redis \
    && rm -rf /tmp/pear ~/.pearrc \
    && apk del --no-cache .php-build-deps

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR ${APP_DIR}

# Copy application code (respects .dockerignore)
COPY . .

# Install PHP deps (production, no dev). Lockfile is gitignored, so use composer update.
RUN composer install --no-dev --optimize-autoloader --no-interaction || \
    composer update --no-dev --optimize-autoloader --no-interaction

# Permissions: php-fpm runs as www-data
RUN chown -R www-data:www-data ${APP_DIR} \
    && chmod -R 775 storage bootstrap/cache config

# Cron entry for Laravel scheduler
COPY docker/laravel.crontab /etc/crontabs/root

# Supervisord + nginx + entrypoint
COPY docker/supervisord.conf      /etc/supervisord.conf
COPY docker/nginx.conf            /etc/nginx/http.d/default.conf
COPY docker/entrypoint.sh         /entrypoint.sh
COPY docker/init-db.php           /tmp/init-db.php
COPY docker/db-ping.php           /tmp/db-ping.php
RUN  chmod +x /entrypoint.sh \
    && sed -i 's/^user = .*/user = www-data/' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/^group = .*/group = www-data/' /usr/local/etc/php-fpm.d/www.conf

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisord.conf"]
