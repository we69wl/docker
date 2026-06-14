#!/bin/bash

# ========================================================================
# mount_share.sh — Подключение сетевой папки Windows (SMB/CIFS) в Astra Linux
# Запускается от root/sudo, монтирует шару для указанного пользователя
# ========================================================================

set -e
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Скрипт должен запускаться с правами root (sudo)${NC}"
    exit 1
fi

# --- Проверка cifs-utils ---
if ! command -v mount.cifs &>/dev/null; then
    echo -e "${YELLOW}[*] Пакет cifs-utils не установлен. Устанавливаю...${NC}"
    apt-get install -y cifs-utils
fi

echo -e "${CYAN}"
echo "============================================="
echo " Подключение сетевой папки Windows (CIFS) "
echo "============================================="
echo -e "${NC}"

# --- Сбор параметров ---
# Пользователь системы
while true; do
    read -rp "Имя пользователя Astra Linux (для кого монтируем): " LINUX_USER
    if id "$LINUX_USER" &>/dev/null; then
        LINUX_UID=$(id -u "$LINUX_USER")
        LINUX_GID=$(id -g "$LINUX_USER")
    break
    else
        echo -e "${RED}[!] Пользователь '$LINUX_USER' не найден. Попробуйте снова.${NC}"
    fi
done

# Адрес сервера
read -rp "IP или имя Windows-сервера (например: 192.168.1.100): " SMB_SERVER
# Имя шары
read -rp "Имя сетевой папки (например: scan): " SMB_SHARE
# Подпапка внутри шары
read -rp "Подпапка внутри шары (Enter - пропустить): " SMB_SUBDIR


# Точка монтирования
DEFAULT_MOUNT="/mnt/${SMB_SHARE}"
read -rp "Точка монтирования [${DEFAULT_MOUNT}]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT}"
# Учётные данные Windows
read -rp "Имя пользователя Windows для подключения: " WIN_USER
read -rsp "Пароль Windows: " WIN_PASS
echo
read -rp "Домен/рабочая группа (Enter — пропустить): " WIN_DOMAIN
# Версия SMB
echo -e "\nВерсия протокола SMB:"
echo " 1) Авто (рекомендуется для Windows 10/2016+)"
echo " 2) 3.0"
echo " 3) 2.0"
echo " 4) 1 (старые серверы / Astra Linux SE 1.6)"
read -rp "Выберите [1]: " SMB_VER_CHOICE
case "$SMB_VER_CHOICE" in
    2) SMB_VERS="vers=3.0," ;;
    3) SMB_VERS="vers=2.0," ;;
    4) SMB_VERS="vers=1.0," ;;
    *) SMB_VERS="" ;;
esac
# Постоянное монтирование?
read -rp "Добавить в /etc/fstab (автомонтирование при загрузке)? [Y/n]: " ADD_FSTAB
ADD_FSTAB="${ADD_FSTAB:-Y}"

SMB_PATH="//${SMB_SERVER}/${SMB_SHARE}${SMB_SUBDIR:+/$SMB_SUBDIR}"

echo -e "\n${CYAN}--- Итоговые параметры ---${NC}"
echo " Пользователь Linux : $LINUX_USER (uid=$LINUX_UID, gid=$LINUX_GID)"
echo " Шара : ${SMB_PATH}"
echo " Точка монтирования : $MOUNT_POINT"
echo " Пользователь Win : $WIN_USER"
[[ -n "$WIN_DOMAIN" ]] && echo " Домен : $WIN_DOMAIN"
[[ -n "$SMB_VERS" ]] && echo " Версия SMB : ${SMB_VERS%,}"
echo ""
read -rp "Продолжить? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# --- Создание точки монтирования ---
if [[ ! -d "$MOUNT_POINT" ]]; then
    mkdir -p "$MOUNT_POINT"
    echo -e "${GREEN}[+] Создана точка монтирования: $MOUNT_POINT${NC}"
fi
# --- Файл учётных данных ---
CRED_DIR="/etc/samba"
CRED_FILE="${CRED_DIR}/.creds_${LINUX_USER}_${SMB_SHARE}"
mkdir -p "$CRED_DIR"
cat > "$CRED_FILE" <<EOF
    username=${WIN_USER}
    password=${WIN_PASS}
EOF
[[ -n "$WIN_DOMAIN" ]] && echo "domain=${WIN_DOMAIN}" >> "$CRED_FILE"
chmod 600 "$CRED_FILE"
echo -e "${GREEN}[+] Файл учётных данных: $CRED_FILE${NC}"
# --- Монтирование ---
MOUNT_OPTS="${SMB_VERS}credentials=${CRED_FILE},uid=${LINUX_UID},gid=${LINUX_GID},iocharset=utf8,file_mode=0664,dir_mode=0775,nofail"
echo -e "${CYAN}[*] Монтирую...${NC}"
if mount -t cifs "$SMB_PATH" "$MOUNT_POINT" -o "$MOUNT_OPTS";
then
    echo -e "${GREEN}[+] Успешно смонтировано!${NC}"
else
    echo -e "${RED}[!] Ошибка монтирования. Проверьте параметры и доступность сервера. ${NC}"
    exit 1
fi

# --- Запись в fstab ---
if [[ "$ADD_FSTAB" =~ ^[Yy]$ ]]; then
    FSTAB_LINE="${SMB_PATH} ${MOUNT_POINT} cifs ${MOUNT_OPTS},_netdev,x-systemd.automount 0 0"

    # Проверка — нет ли уже такой записи
    if grep -qsF "$SMB_PATH" /etc/fstab; then
        echo -e "${YELLOW}[!] Запись для ${SMB_PATH} уже есть в /etc/fstab — пропускаю.${NC}"
    else
        # Бэкап fstab
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
        echo "$FSTAB_LINE" >> /etc/fstab
        echo -e "${GREEN}[+] Запись добавлена в /etc/fstab${NC}"
    fi
fi

echo -e "\n${GREEN}Готово! Папка доступна по пути: ${MOUNT_POINT}${NC}"
echo -e "Пользователь ${LINUX_USER} может читать и писать файлы туда.\n"