#!/usr/bin/env bash
# =================================================================
#  common.sh — общие функции и константы для скриптов pc/
#  Подключение: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# =================================================================

PC_DB_ENC="${HOME}/.config/pc/computers.tsv.gpg"
ADMIN_USER="${ADMIN_USER:-administrator}"
SSH_TIMEOUT="${SSH_TIMEOUT:-5}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# Проверить наличие команды; при отсутствии — напечатать ошибку и выйти
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}Ошибка:${RESET} $1 не установлен." >&2
    exit 1
  fi
}

# Копировать строку в буфер обмена X11 и сообщить об этом
_copy() {
  if command -v xclip &>/dev/null; then
    echo -n "$1" | xclip -selection clipboard
  elif command -v xsel &>/dev/null; then
    echo -n "$1" | xsel --clipboard --input
  else
    echo -e "${YELLOW}Буфер недоступен.${RESET} Пароль: ${BOLD}$1${RESET}"
    return
  fi
  echo -e "${GREEN}✓ Скопировано в буфер обмена${RESET}"
}

# Настроить gpg-agent: не кешировать пароль, разрешить loopback-пинентри
setup_gpg_agent() {
  local conf="${HOME}/.gnupg/gpg-agent.conf"
  mkdir -p "${HOME}/.gnupg" && chmod 700 "${HOME}/.gnupg"
  if ! grep -q "default-cache-ttl" "$conf" 2>/dev/null; then
    printf "default-cache-ttl 0\nmax-cache-ttl 0\n" >> "$conf"
  fi
  if ! grep -q "allow-loopback-pinentry" "$conf" 2>/dev/null; then
    echo "allow-loopback-pinentry" >> "$conf"
  fi
  gpg-connect-agent reloadagent /bye &>/dev/null
}

# Расшифровать GPG файл в stdout.
# Использование: gpg_decrypt [файл]   (по умолчанию — $PC_DB_ENC)
# При ошибке печатает в stderr и возвращает код 1.
gpg_decrypt() {
  local file="${1:-$PC_DB_ENC}"
  if [[ ! -f "$file" ]]; then
    echo -e "${RED}Файл базы не найден:${RESET} $file" >&2
    return 1
  fi
  local data
  data=$(gpg --decrypt --pinentry-mode loopback "$file" 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$data" ]]; then
    echo -e "${RED}Ошибка расшифровки. Неверный мастер-пароль?${RESET}" >&2
    return 1
  fi
  echo "$data"
}

# Выполнить команду через SSH+sudo на удалённой машине.
# Использование: ssh_run IP PASSWORD <<< "команда"
# Возвращает stdout команды; при ошибке подключения — пустая строка.
ssh_run() {
  local ip="$1" password="$2"
  local remote_cmd
  remote_cmd=$(cat)
  local ssh_opts=(-o StrictHostKeyChecking=no -o "ConnectTimeout=${SSH_TIMEOUT}" -o BatchMode=no -o LogLevel=ERROR)
  if command -v sshpass &>/dev/null && [[ -n "$password" ]]; then
    sshpass -p "$password" ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" \
      "/usr/bin/sudo -S /bin/bash -s" <<< "${password}"$'\n'"${remote_cmd}" 2>/dev/null
  else
    ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" \
      "/usr/bin/sudo /bin/bash -s" <<< "$remote_cmd" 2>/dev/null
  fi
}

# Записать строку в лог-файл с временной меткой и уровнем.
# Требует установленной переменной LOG_FILE.
log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "${LOG_FILE:-/tmp/script.log}"
}
