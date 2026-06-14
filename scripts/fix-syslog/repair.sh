#!/bin/bash
# fix-syslog-ng.sh — устраняет сбой подсистемы регистрации событий Astra Linux
# Причина: рассинхронизация persist-файла syslog-ng при загрузке системы
# Использование: sudo bash fix-syslog-ng.sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[>>]${NC} $1"; }
err() { echo -e "${RED}[!!]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "Запустите скрипт с правами root: sudo bash $0"
    exit 1
fi

echo ""
echo "=================================================="
echo " fix-syslog-ng — восстановление регистрации событий"
echo "=================================================="
echo ""

# 1 Проверить текущий статус
warn "Проверяю статус syslog-ng..."
if systemctl is-active --quiet syslog-ng; then
    log "syslog-ng сейчас запущен"
    WAS_RUNNING=true
else
    warn "syslog-ng не запущен"
    WAS_RUNNING=false
fi

# 2 Остановить службу
warn "Останавливаю syslog-ng..."
systemctl stop syslog-ng
log "Остановлен"

# 3 Удалить повреждённый persist-файл
PERSIST_FILE="/var/lib/syslog-ng/syslog-ng.persist"
if [[ -f "$PERSIST_FILE" ]]; then
    BACKUP="${PERSIST_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$PERSIST_FILE" "$BACKUP"
    log "Резервная копия: $BACKUP"
    rm -f "$PERSIST_FILE"
    log "Persist-файл удалён (будет создан заново)"
else
    warn "Persist-файл не найден (возможно, уже удалён): $PERSIST_FILE"
fi

# 4 Убедиться что автозапуск включён
systemctl enable syslog-ng --quiet 2>/dev/null || true
log "Автозапуск syslog-ng включён"
# 5 Запустить службу
warn "Запускаю syslog-ng..."
systemctl start syslog-ng
sleep 2
if systemctl is-active --quiet syslog-ng; then
    log "syslog-ng успешно запущен"
else
    err "syslog-ng не запустился! Проверьте: journalctl -u syslog-ng -n 30"
    exit 1
fi

# 6 Перезапустить диагностику событий Astra
warn "Перезапускаю подсистему диагностики событий..."
if systemctl list-unit-files | grep -q "astra-event-diagnostics"; then
    systemctl restart astra-event-diagnostics 2>/dev/null && log "astra-event-diagnostics
    перезапущен" || warn "Не удалось перезапустить astra-event-diagnostics"
fi

if systemctl list-unit-files | grep -q "parsec.service"; then
    systemctl restart parsec 2>/dev/null && log "parsec перезапущен" || warn "Не удалось перезапустить parsec"
fi

# 7 Итоговая проверка
echo ""
echo "=================================================="
echo " Итог"
echo "=================================================="
systemctl status syslog-ng --no-pager -l | grep -E "Active:|Main PID:"
# Проверить файл диагностики
sleep 3
DIAG_FILE="/parsec/log/astra/astra-event-diagnostics"
if [[ -f "$DIAG_FILE" ]]; then
    ERRORS=$(grep -c "critical" "$DIAG_FILE" 2>/dev/null || echo 0)
    if [[ "$ERRORS" -eq 0 ]]; then
        log "Файл диагностики: ошибок нет"
    else
        warn "В файле диагностики есть записи critical: $ERRORS шт."
        warn "Проверьте: sudo tail -20 $DIAG_FILE"
    fi
fi

echo ""
log "Готово. Красное уведомление должно исчезнуть."
echo ""
echo "Для проверки после следующей перезагрузки:"
echo " sudo cat /parsec/log/astra/astra-event-diagnostics"
echo ""

# 8 Опциональная установка как systemd-сервис (при загрузке)
echo "=================================================="
echo " Установить как автоматическое исправление при загрузке?"
echo " (создаст systemd-сервис, который запускается после syslog-ng)"
echo "=================================================="
read -r -p " Установить? [y/N]: " INSTALL_SERVICE
if [[ "$INSTALL_SERVICE" =~ ^[Yy]$ ]]; then
    SCRIPT_PATH="/usr/local/sbin/fix-syslog-ng.sh"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    cat > /etc/systemd/system/fix-syslog-ng-persist.service << 'EOF'
            [Unit]
            Description=Fix syslog-ng persist file on boot
            After=syslog-ng.service
            Wants=syslog-ng.service
            [Service]
            Type=oneshot
            ExecStartPre=/bin/sleep 5
            ExecStart=/bin/bash -c '
                if [ -f /var/lib/syslog-ng/syslog-ng.persist ]; then
                    systemctl stop syslog-ng
                    rm -f /var/lib/syslog-ng/syslog-ng.persist
                    systemctl start syslog-ng
                fi
            '
            RemainAfterExit=yes
            [Install]
            WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable fix-syslog-ng-persist.service --quiet
    log "Сервис fix-syslog-ng-persist.service установлен и включён"
    warn "При каждой загрузке persist-файл будет автоматически пересоздаваться"
else
    warn "Автоматическое исправление не установлено"
fi

echo ""
log "Скрипт завершён."