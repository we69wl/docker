FROM php:8.5-fpm

RUN apt-get update && apt-get install -y git unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
    pdo \
    pdo_mysql \
    mysqli \
    mbstring \
    bcmath \
    exif \
    pcntl \
    gd \
    zip \
    opcache \
    redis

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

CMD ["php-fpm"]