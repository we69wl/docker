FROM php:8.3-fpm

# Установка системных зависимостей
RUN apt-get update && apt-get install -y git unzip \
    && rm -rf /var/lib/apt/lists/*

# Утилита для удобной установки PHP-расширений
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# Установка необходимых расширений для WordPress / Laravel
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

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Рабочая директория внутри контейнера
WORKDIR /var/www

CMD ["php-fpm"]