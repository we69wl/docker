#!/bin/bash
set -e

SITE=$1  # например: savin-it.ru или dev-react-tables
WWW_PATH="./nginx/www/$SITE"

if [ -z "$SITE" ]; then
  echo "Usage: ./deploy.sh <site-folder>"
  exit 1
fi

echo "Pulling $SITE..."
git -C "$WWW_PATH" pull origin main

# Для PHP-сайтов — перезагрузить php-fpm
if docker ps --format '{{.Names}}' | grep -q php-fpm; then
  docker exec php-fpm kill -USR2 1
fi

echo "Done: $SITE deployed"