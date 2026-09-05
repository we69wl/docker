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

# Разрешаем слушать на всех интерфейсах для доступа из других контейнеров
RUN echo "listen = 0.0.0.0:9000" >> /usr/local/etc/php-fpm.d/zz-docker.conf

WORKDIR /var/www/html
CMD ["php-fpm"]