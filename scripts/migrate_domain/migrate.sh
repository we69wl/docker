#!/bin/bash

# ============================================================
# Скрипт миграции компа из Windows AD (winbind) в ALD Pro
# Структура хомяка: /home/%D/%U  (например /home/ATOMTES/vlaysavin)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

# --- Проверка прав ---
if [ "$EUID" -ne 0 ]; then
    error "Запустите скрипт с правами root: sudo $0"
fi

echo ""
echo "=============================================="
echo "   Миграция: Windows AD (winbind) -> ALD Pro"
echo "=============================================="
echo ""

info "Введите параметры миграции:"
echo ""

read -p "Старый домен Windows AD (например ATOMTES): " OLD_DOMAIN
read -p "Realm старого домена (например ATOMTES.RU): " OLD_REALM
read -p "Новый домен ALD Pro (например atomtes.ru): " NEW_DOMAIN
read -p "Контроллер нового домена ALD Pro (например dc01.atomtes.ru): " DC
read -p "IP контроллера нового домена: " DC_IP
read -p "Имя компьютера (только строчные буквы): " COMPUTER_NAME
read -p "Логин пользователя в старом домене (winbind): " OLD_USER
read -p "Логин пользователя в новом домене ALD Pro: " NEW_USER
read -p "Логин администратора нового домена ALD Pro: " ALDPRO_ADMIN
echo -n "Пароль администратора Windows AD (для вывода из домена): "
read -s AD_ADMIN_PASS
echo ""
echo -n "Пароль администратора ALD Pro (для ввода в домен): "
read -s ALDPRO_ADMIN_PASS
echo ""

OLD_HOME="/home/${OLD_DOMAIN}/${OLD_USER}"
NEW_DOMAIN_UPPER=$(echo "${NEW_DOMAIN}" | tr '[:lower:]' '[:upper:]')
NEW_HOME="/home/${NEW_DOMAIN_UPPER}/${NEW_USER}"

echo ""
echo "=============================================="
echo " Старый домен (WinAD): ${OLD_DOMAIN} / ${OLD_REALM}"
echo " Новый домен (ALD Pro): ${NEW_DOMAIN}"
echo " Контроллер ALD Pro:   ${DC} (${DC_IP})"
echo " Компьютер:            ${COMPUTER_NAME}"
echo " Пользователь:         ${OLD_USER} -> ${NEW_USER}"
echo " Старый хомяк:         ${OLD_HOME}"
echo " Новый хомяк:          ${NEW_HOME}"
echo "=============================================="
echo ""
read -p "Всё верно? Продолжить? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && error "Отменено"

# --- Шаг 1: Резервная копия хомяка ---
log "Шаг 1: Резервная копия домашней папки..."
if [ -d "$OLD_HOME" ]; then
    BACKUP="/tmp/backup_${OLD_USER}_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$BACKUP" -C "$(dirname $OLD_HOME)" "$(basename $OLD_HOME)" 2>/dev/null
    log "Резервная копия создана: $BACKUP"
else
    warn "Домашняя папка ${OLD_HOME} не найдена — пропускаем"
fi

# --- Шаг 2: Вывод из Windows AD через net ads ---
log "Шаг 2: Вывод из Windows AD..."
echo "$AD_ADMIN_PASS" | net ads leave -U "Administrator%${AD_ADMIN_PASS}" 2>/dev/null \
    && log "Вывод из Windows AD выполнен" \
    || warn "net ads leave не сработал — продолжаем"

# Останавливаем и отключаем winbind
systemctl stop winbind 2>/dev/null
systemctl disable winbind 2>/dev/null
log "winbind остановлен"

# --- Шаг 3: Очистка ---
log "Шаг 3: Очистка старых конфигов..."
systemctl stop sssd 2>/dev/null
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*
rm -f /etc/sssd/sssd.conf
rm -f /etc/sssd/sssd.conf.deleted
rm -f /etc/ipa/default.conf
rm -f /etc/krb5.keytab
rm -f /etc/krb5.conf
rm -f /var/lib/samba/private/secrets.tdb 2>/dev/null
rm -f /var/lib/samba/private/schannel_store.tdb 2>/dev/null
sed -i "/${OLD_DOMAIN,,}/Id" /etc/hosts 2>/dev/null
log "Очистка завершена"

# --- Шаг 4: Настройка DNS ---
log "Шаг 4: Настройка DNS..."
cat > /etc/resolv.conf << EOF
search ${NEW_DOMAIN}
nameserver ${DC_IP}
EOF
log "DNS настроен"

# --- Шаг 5: Настройка hosts ---
log "Шаг 5: Настройка /etc/hosts..."
sed -i "/${DC}/d" /etc/hosts
echo "${DC_IP}   ${DC} $(echo ${DC} | cut -d. -f1)" >> /etc/hosts
log "Hosts настроен"

# --- Шаг 6: CA сертификат ---
log "Шаг 6: Скачивание CA сертификата ALD Pro..."
curl -k -o /tmp/ca.crt "http://${DC}/ipa/config/ca.crt" 2>/dev/null
[ -f /tmp/ca.crt ] && [ -s /tmp/ca.crt ] \
    && log "CA сертификат получен" \
    || warn "Не удалось получить CA сертификат"

# --- Шаг 7: Ввод в ALD Pro ---
log "Шаг 7: Ввод в домен ALD Pro ${NEW_DOMAIN}..."
echo ""

/opt/rbta/aldpro/client/bin/aldpro-client-installer \
    --domain "${NEW_DOMAIN}" \
    --account "${ALDPRO_ADMIN}" \
    --password "${ALDPRO_ADMIN_PASS}" \
    --host "${COMPUTER_NAME}" \
    --force

if [ $? -ne 0 ]; then
    warn "aldpro-client-installer не сработал — пробуем через ipa-client-install..."

    if [ -f /tmp/ca.crt ] && [ -s /tmp/ca.crt ]; then
        echo "${ALDPRO_ADMIN_PASS}" | ipa-client-install \
            --domain "${NEW_DOMAIN}" \
            --server "${DC}" \
            --principal "${ALDPRO_ADMIN}" \
            --hostname "${COMPUTER_NAME}.${NEW_DOMAIN}" \
            --ca-cert-file /tmp/ca.crt \
            --force-join \
            --unattended \
            --no-ntp \
            -w -
    else
           echo "${ALDPRO_ADMIN_PASS}" | ipa-client-install \
            --domain "${NEW_DOMAIN}" \
            --server "${DC}" \
            --principal "${ALDPRO_ADMIN}" \
            --hostname "${COMPUTER_NAME}.${NEW_DOMAIN}" \
            --force-join \
            --unattended \
            --no-ntp \
            -w -
    fi
fi

# --- Шаг 8: Исправление krb5.conf ---
log "Шаг 8: Проверка krb5.conf..."
if [ -f /etc/krb5.conf ]; then
    if ! grep -qi "${DC}" /etc/krb5.conf 2>/dev/null; then
        warn "Исправляем krb5.conf..."
        sed -i "s/kdc = .*/kdc = ${DC}/" /etc/krb5.conf
        sed -i "s/admin_server = .*/admin_server = ${DC}/" /etc/krb5.conf
        log "krb5.conf исправлен"
    fi
fi

# --- Шаг 9: Скрипт для rsync ---
log "Шаг 9: Создание скрипта копирования файлов..."
cat > /tmp/copy_home.sh << EOF
#!/bin/bash
OLD_HOME="${OLD_HOME}"
NEW_HOME="${NEW_HOME}"

if [ ! -d "\$OLD_HOME" ]; then
    echo "Старый хомяк не найден: \$OLD_HOME"
    exit 1
fi

if [ ! -d "\$NEW_HOME" ]; then
    echo "Новый хомяк не найден: \$NEW_HOME"
    echo "Сначала войдите под ${NEW_USER}@${NEW_DOMAIN} чтобы создался хомяк"
    exit 1
fi

echo "Копирование файлов из \$OLD_HOME в \$NEW_HOME..."
rsync -av --progress "\$OLD_HOME/" "\$NEW_HOME/"
chown -R "${NEW_USER}@${NEW_DOMAIN}": "\$NEW_HOME/"
echo "Готово!"
EOF
chmod +x /tmp/copy_home.sh
log "Скрипт копирования создан: /tmp/copy_home.sh"

# --- Итог ---
echo ""
echo "=============================================="
log "Миграция завершена!"
echo "=============================================="
echo ""
info "После перезагрузки:"
echo "  1. Войдите под ${NEW_USER}@${NEW_DOMAIN}"
echo "  2. Откройте терминал и запустите:"
echo "     sudo bash /tmp/copy_home.sh"
echo ""
read -p "Нажмите Enter для перезагрузки..."
reboot