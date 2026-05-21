#!/usr/bin/env bash
# ============================================================
#  pc — быстрый доступ к паролям и подключению к компам
#  Формат CSV: имя сотрудника,ip,пароль
#  Хранение: зашифрованный GPG файл
# ============================================================

PC_DB_ENC="${HOME}/.config/pc/computers.csv.gpg"
PC_DB_PLAIN="${HOME}/.config/pc/computers.csv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ---------- проверка зависимостей ----------
if ! command -v fzf &>/dev/null; then
  echo -e "${RED}Ошибка:${RESET} fzf не установлен."
  echo "  Скопируй бинарник fzf в /usr/local/bin/ и chmod +x"
  exit 1
fi

if ! command -v gpg &>/dev/null; then
  echo -e "${RED}Ошибка:${RESET} gpg не установлен."
  echo "  sudo apt install gnupg"
  exit 1
fi

# ---------- копирование в буфер ----------
_copy() {
  if command -v xclip &>/dev/null; then
    echo -n "$1" | xclip -selection clipboard
  elif command -v xsel &>/dev/null; then
    echo -n "$1" | xsel --clipboard --input
  elif command -v pbcopy &>/dev/null; then
    echo -n "$1" | pbcopy
  else
    echo -e "${YELLOW}Буфер недоступен.${RESET} Пароль: ${BOLD}$1${RESET}"
    return
  fi
  echo -e "${GREEN}✓ Скопировано в буфер обмена${RESET}"
}

# ---------- настройка gpg-agent (без кэша — пароль каждый раз) ----------
_setup_gpg_agent() {
  local conf="${HOME}/.gnupg/gpg-agent.conf"
  mkdir -p "${HOME}/.gnupg"
  chmod 700 "${HOME}/.gnupg"

  # TTL = 0 — gpg-agent не кэширует, пароль спрашивается каждый раз
  if ! grep -q "default-cache-ttl" "$conf" 2>/dev/null; then
    echo "default-cache-ttl 0" >> "$conf"
    echo "max-cache-ttl 0" >> "$conf"
    gpg-connect-agent reloadagent /bye &>/dev/null
  fi
}

# ---------- первый запуск: создать и зашифровать базу ----------
_first_run() {
  mkdir -p "$(dirname "$PC_DB_PLAIN")"
  echo -e "${YELLOW}Первый запуск — создаём базу компов.${RESET}"
  echo ""
  echo -e "Будет создан файл: ${BOLD}$PC_DB_PLAIN${RESET}"
  echo -e "Формат: ${BOLD}ИМЯ СОТРУДНИКА,IP,ПАРОЛЬ${RESET}"
  echo ""
  echo "Пример содержимого:"
  echo "  employee,ip,password"
  echo "  Иванов Иван,192.168.111.5,Admin@2024"
  echo "  Петрова Мария,192.168.121.12,Qwerty123!"
  echo ""
  echo -e "${CYAN}Заполни файл и запусти:${RESET} pc --encrypt"
  echo ""

  # Создаём файл с заголовком
  echo "employee,ip,password" > "$PC_DB_PLAIN"
  chmod 600 "$PC_DB_PLAIN"
  echo -e "${GREEN}✓ Файл создан:${RESET} $PC_DB_PLAIN"
}

# ---------- зашифровать plain CSV → gpg ----------
_encrypt() {
  if [[ ! -f "$PC_DB_PLAIN" ]]; then
    echo -e "${RED}Файл не найден:${RESET} $PC_DB_PLAIN"
    exit 1
  fi

  echo -e "${CYAN}Шифруем базу...${RESET}"
  echo -e "${YELLOW}Введи мастер-пароль (запомни его — он нужен для доступа к базе):${RESET}"

  gpg --symmetric \
      --cipher-algo AES256 \
      --output "$PC_DB_ENC" \
      "$PC_DB_PLAIN"

  if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓ База зашифрована:${RESET} $PC_DB_ENC"
    # Удаляем незашифрованный файл
    shred -u "$PC_DB_PLAIN" 2>/dev/null || rm -f "$PC_DB_PLAIN"
    echo -e "${GREEN}✓ Незашифрованный файл удалён${RESET}"
  else
    echo -e "${RED}Ошибка шифрования${RESET}"
    exit 1
  fi
}

# ---------- редактировать базу ----------
_edit() {
  echo -e "${CYAN}Расшифровываем для редактирования...${RESET}"
  gpg --decrypt --output "$PC_DB_PLAIN" "$PC_DB_ENC" 2>/dev/null

  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки. Неверный пароль?${RESET}"
    exit 1
  fi

  chmod 600 "$PC_DB_PLAIN"
  "${EDITOR:-nano}" "$PC_DB_PLAIN"

  echo -e "${CYAN}Сохраняем и шифруем обратно...${RESET}"
  gpg --symmetric \
      --cipher-algo AES256 \
      --batch \
      --yes \
      --output "$PC_DB_ENC" \
      "$PC_DB_PLAIN"

  shred -u "$PC_DB_PLAIN" 2>/dev/null || rm -f "$PC_DB_PLAIN"
  echo -e "${GREEN}✓ База обновлена и зашифрована${RESET}"
}

# ---------- обработка аргументов ----------
case "$1" in
  --encrypt)
    _setup_gpg_agent
    _encrypt
    exit 0
    ;;
  --edit)
    _setup_gpg_agent
    _edit
    exit 0
    ;;
  --help|-h)
    echo ""
    echo -e "  ${BOLD}pc${RESET}           — открыть меню поиска"
    echo -e "  ${BOLD}pc --edit${RESET}    — добавить/изменить записи"
    echo -e "  ${BOLD}pc --encrypt${RESET} — зашифровать plain CSV (первый раз)"
    echo ""
    exit 0
    ;;
esac

# ---------- первый запуск ----------
_setup_gpg_agent

if [[ ! -f "$PC_DB_ENC" ]]; then
  _first_run
  exit 0
fi

# ---------- расшифровываем в память (не на диск) ----------
CSV_DATA=$(gpg --decrypt "$PC_DB_ENC" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$CSV_DATA" ]]; then
  echo -e "${RED}Ошибка расшифровки. Неверный мастер-пароль?${RESET}"
  exit 1
fi

# ---------- выбор сотрудника через fzf ----------
SELECTED=$(echo "$CSV_DATA" \
  | tail -n +2 \
  | grep -v '^\s*$' \
  | awk -F',' '{printf "%-25s %-18s %s\n", $1, $2, $3}' \
  | fzf \
      --prompt="🖥  Поиск > " \
      --header="  Сотрудник                IP                 Пароль" \
      --height=50% \
      --reverse \
      --border=rounded \
      --color="header:cyan,prompt:yellow,pointer:green")

[[ -z "$SELECTED" ]] && exit 0

# ---------- вытаскиваем данные обратно из CSV ----------
EMPLOYEE_KEY=$(echo "$SELECTED" | awk '{print $1}')
CSV_LINE=$(echo "$CSV_DATA" \
  | tail -n +2 \
  | grep -v '^\s*$' \
  | awk -F',' -v key="$EMPLOYEE_KEY" 'index($1, key) {print; exit}')

EMPLOYEE=$(echo "$CSV_LINE" | cut -d',' -f1 | xargs)
IP=$(echo "$CSV_LINE"       | cut -d',' -f2 | xargs)
PASSWORD=$(echo "$CSV_LINE" | cut -d',' -f3 | xargs)

# ---------- меню действий ----------
echo ""
echo -e "  ${BOLD}${CYAN}Сотрудник:${RESET} $EMPLOYEE"
echo -e "  ${BOLD}${CYAN}IP:${RESET}        $IP"
echo -e "  ${BOLD}${CYAN}Пароль:${RESET}    $PASSWORD"
echo ""

ACTION=$(printf "📋  Скопировать пароль\n👁  Показать IP + пароль\n🖥  SSH  →  $IP\n🪟  RDP  →  $IP\n❌  Отмена" \
  | fzf \
      --prompt="  Действие > " \
      --height=35% \
      --reverse \
      --border=rounded \
      --color="prompt:yellow,pointer:green")

case "$ACTION" in
  "📋  Скопировать пароль")
    _copy "$PASSWORD"
    ;;
  "👁  Показать IP + пароль")
    echo ""
    echo -e "  Сотрудник : ${BOLD}$EMPLOYEE${RESET}"
    echo -e "  IP        : ${BOLD}${CYAN}$IP${RESET}"
    echo -e "  Пароль    : ${BOLD}${GREEN}$PASSWORD${RESET}"
    echo ""
    ;;
  "🖥  SSH"*)
    echo -e "${CYAN}SSH → ${BOLD}$IP${RESET} (${EMPLOYEE})..."
    ssh "administrator@$IP"
    ;;
  "🪟  RDP"*)
    if command -v xfreerdp &>/dev/null; then
      echo -e "${CYAN}RDP → ${BOLD}$IP${RESET} (${EMPLOYEE})..."
      xfreerdp /v:"$IP" /p:"$PASSWORD" /u:"administrator" /cert:ignore &
    elif command -v rdesktop &>/dev/null; then
      rdesktop -p "$PASSWORD" -u administrator "$IP" &
    else
      echo -e "${YELLOW}Установи xfreerdp:${RESET} sudo apt install freerdp2-x11"
    fi``
    ;;
  *)
    echo -e "${YELLOW}Отмена.${RESET}"
    ;;
esac
