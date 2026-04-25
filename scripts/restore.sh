#!/bin/bash

# Restore script for Docker infrastructure
# Usage: ./scripts/restore.sh <backup_date> (например: ./scripts/restore.sh 20250425_123456)

set -e

BACKUP_DATE=$1
BACKUP_DIR="/opt/backups"
DOCKER_DIR="/opt/docker"

if [ -z "$BACKUP_DATE" ]; then
    echo "❌ Ошибка: укажите дату бэкапа"
    echo "Пример: ./scripts/restore.sh 20250425_123456"
    exit 1
fi

CONFIG_BACKUP="$BACKUP_DIR/config_${BACKUP_DATE}"
MYSQL_BACKUP="$BACKUP_DIR/mysql/all_databases_${BACKUP_DATE}.sql"

echo "🚀 Восстановление из бэкапа $BACKUP_DATE..."

# Восстановление конфигов
if [ -d "$CONFIG_BACKUP" ]; then
    echo "📁 Восстанавливаем конфиги..."
    cp -r "$CONFIG_BACKUP/sites" "$DOCKER_DIR/nginx/"
    cp "$CONFIG_BACKUP/nginx.conf" "$DOCKER_DIR/nginx/"
    echo "✅ Конфиги восстановлены"
fi

# Восстановление MySQL
if docker ps | grep -q mysql-db && [ -f "$MYSQL_BACKUP" ]; then
    echo "📦 Восстанавливаем MySQL..."
    docker exec -i mysql-db mysql < "$MYSQL_BACKUP"
    echo "✅ MySQL восстановлен"
fi

echo "🎉 Восстановление завершено!"
echo "🔄 Перезапустите сервисы: docker compose restart"