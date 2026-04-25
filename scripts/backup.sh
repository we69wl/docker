#!/bin/bash

# Backup script for Docker infrastructure
# Usage: ./scripts/backup.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Конфигурация
BACKUP_DIR="/opt/backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30
DOCKER_DIR="/opt/docker"
LOG_FILE="/opt/backups/backup_${DATE}.log"

# Создаём папку для бэкапов
mkdir -p "$BACKUP_DIR"

# Функция логирования
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция проверки ошибок
check_error() {
    if [ $? -ne 0 ]; then
        log "${RED}❌ Ошибка: $1${NC}"
        exit 1
    fi
}

log "${GREEN}🚀 Начинаем резервное копирование...${NC}"

# 1. Бэкап баз данных (если есть MySQL)
if docker ps | grep -q mysql-db; then
    log "📦 Бэкапим MySQL..."
    
    mkdir -p "$BACKUP_DIR/mysql"
    
    docker exec mysql-db mysqldump \
        --all-databases \
        --single-transaction \
        --quick \
        --skip-lock-tables \
        > "$BACKUP_DIR/mysql/all_databases_${DATE}.sql" 2>> "$LOG_FILE"
    
    check_error "MySQL дамп не создан"
    log "${GREEN}✅ MySQL бэкап создан: $BACKUP_DIR/mysql/all_databases_${DATE}.sql${NC}"
fi

# 2. Бэкап важных конфигов
log "📁 Бэкапим конфигурационные файлы..."

BACKUP_CONFIG_DIR="$BACKUP_DIR/config_${DATE}"
mkdir -p "$BACKUP_CONFIG_DIR"

# Копируем конфиги
cp -r "$DOCKER_DIR"/nginx/sites "$BACKUP_CONFIG_DIR/" 2>> "$LOG_FILE"
cp "$DOCKER_DIR"/nginx/nginx.conf "$BACKUP_CONFIG_DIR/" 2>> "$LOG_FILE"
cp "$DOCKER_DIR"/docker-compose.yml "$BACKUP_CONFIG_DIR/" 2>> "$LOG_FILE"
cp "$DOCKER_DIR"/.env "$BACKUP_CONFIG_DIR/" 2>> "$LOG_FILE" || log "${YELLOW}⚠️ .env не найден${NC}"
cp "$DOCKER_DIR"/python/.env "$BACKUP_CONFIG_DIR/python.env" 2>> "$LOG_FILE" || log "${YELLOW}⚠️ python/.env не найден${NC}"

log "${GREEN}✅ Конфиги сохранены в $BACKUP_CONFIG_DIR${NC}"

# 3. Удаляем старые бэкапы (старше RETENTION_DAYS)
log "🗑️ Удаляем бэкапы старше $RETENTION_DAYS дней..."
find "$BACKUP_DIR" -type f -name "*.sql" -mtime +$RETENTION_DAYS -delete 2>> "$LOG_FILE"
find "$BACKUP_DIR" -type d -name "config_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>> "$LOG_FILE"

# 4. Архивируем всё (опционально)
if [ -f "$BACKUP_CONFIG_DIR/docker-compose.yml" ]; then
    BACKUP_ARCHIVE="$BACKUP_DIR/backup_${DATE}.tar.gz"
    tar -czf "$BACKUP_ARCHIVE" -C "$BACKUP_DIR" "config_${DATE}" "mysql" 2>> "$LOG_FILE"
    log "${GREEN}📦 Архив создан: $BACKUP_ARCHIVE${NC}"
fi

log "${GREEN}🎉 Резервное копирование завершено!${NC}"
echo "-----------------------------------"
echo "Backup directory: $BACKUP_DIR"
echo "Log file: $LOG_FILE"
echo "-----------------------------------"