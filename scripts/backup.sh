#!/bin/bash
# /home/webowl/docker/scripts/backup.sh

# Настройки
BACKUP_ROOT="/mnt/backup/docker"
SOURCE_DIR="/home/webowl/docker"
DATE=$(date +%Y%m%d_%H%M)
LOG_FILE="/home/webowl/docker/logs/backup.log"

# Убедимся, что папка существует
mkdir -p "$BACKUP_ROOT"/{mysql,certbot,env,configs}

echo "=========================================" >> $LOG_FILE
echo "Backup started at $(date)" >> $LOG_FILE

# 1. Бэкап MySQL (только если контейнер запущен)
if docker ps --format '{{.Names}}' | grep -q mysql-db; then
    # Загрузить пароль из .env
    if [ -f "$SOURCE_DIR/.env" ]; then
        source "$SOURCE_DIR/.env"
        if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
            docker exec mysql-db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases 2>/dev/null | \
                gzip > "$BACKUP_ROOT/mysql/mysql_$DATE.sql.gz"
            echo "✓ MySQL dump created" >> $LOG_FILE
        else
            echo "⚠ MYSQL_ROOT_PASSWORD not set in .env" >> $LOG_FILE
        fi
    else
        echo "⚠ .env file not found, skipping MySQL backup" >> $LOG_FILE
    fi
else
    echo "⚠ MySQL container not running, skipping" >> $LOG_FILE
fi

# 2. Бэкап сертификатов
if [ -d "$SOURCE_DIR/certbot/conf" ]; then
    tar -czf "$BACKUP_ROOT/certbot/certbot_$DATE.tar.gz" \
        -C "$SOURCE_DIR" certbot/conf 2>/dev/null
    echo "✓ Certbot backup created" >> $LOG_FILE
fi

# 3. Бэкап .env и credentials.json
[ -f "$SOURCE_DIR/.env" ] && cp "$SOURCE_DIR/.env" "$BACKUP_ROOT/env/env_$DATE"
[ -f "$SOURCE_DIR/python/.env" ] && cp "$SOURCE_DIR/python/.env" "$BACKUP_ROOT/env/python_env_$DATE"
[ -f "$SOURCE_DIR/python/credentials.json" ] && cp "$SOURCE_DIR/python/credentials.json" "$BACKUP_ROOT/env/credentials_$DATE.json"
echo "✓ Env files backed up" >> $LOG_FILE

# 4. Бэкап конфигов nginx
if [ -d "$SOURCE_DIR/nginx/sites" ]; then
    tar -czf "$BACKUP_ROOT/configs/nginx_sites_$DATE.tar.gz" \
        -C "$SOURCE_DIR" nginx/sites 2>/dev/null
    echo "✓ Nginx configs backed up" >> $LOG_FILE
fi

# 5. Бэкап docker-compose.yml
if [ -f "$SOURCE_DIR/docker-compose.yml" ]; then
    cp "$SOURCE_DIR/docker-compose.yml" "$BACKUP_ROOT/configs/docker-compose_$DATE.yml"
    echo "✓ docker-compose.yml backed up" >> $LOG_FILE
fi

# 6. Очистка старых бэкапов (старше 30 дней)
find "$BACKUP_ROOT/mysql" -name "*.sql.gz" -mtime +30 -delete 2>/dev/null
find "$BACKUP_ROOT/certbot" -name "*.tar.gz" -mtime +30 -delete 2>/dev/null
find "$BACKUP_ROOT/env" -type f -mtime +30 -delete 2>/dev/null
find "$BACKUP_ROOT/configs" -type f -mtime +30 -delete 2>/dev/null

echo "Backup completed at $(date)" >> $LOG_FILE
echo "=========================================" >> $LOG_FILE