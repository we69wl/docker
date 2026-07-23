#!/usr/bin/env bash
# ============================================================
#  pc — быстрый доступ к паролям и подключению к компам
#  Формат TSV: название TAB ip TAB пароль TAB тип
#  Типы: pc | printer | bios
#  Хранение: зашифрованный GPG файл
#  Использование:
#    pc            — открыть меню
#    pc --edit     — редактировать базу
#    pc --encrypt  — зашифровать plain TSV (первый раз)
# ============================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PC_DB_PLAIN="${HOME}/.config/pc/computers.tsv"

# ---------- проверка зависимостей ----------
if ! command -v fzf &>/dev/null; then
  echo -e "${RED}Ошибка:${RESET} fzf не установлен."
  echo "  Скопируй бинарник fzf в /usr/local/bin/ и chmod +x"
  exit 1
fi
check_dep gpg

# ---------- первый запуск ----------
_first_run() {
  mkdir -p "$(dirname "$PC_DB_PLAIN")"
  echo -e "${YELLOW}Первый запуск — создаём базу.${RESET}"
  echo ""
  echo -e "Файл: ${BOLD}$PC_DB_PLAIN${RESET}"
  echo -e "Формат: ${BOLD}НАЗВАНИЕ[TAB]IP[TAB]ПАРОЛЬ[TAB]ТИП${RESET}"
  echo -e "Типы: ${BOLD}pc${RESET} | ${BOLD}printer${RESET} | ${BOLD}bios${RESET}"
  echo ""
  echo "Пример:"
  printf "  Иванов Иван\t192.168.111.5\tAdmin@2024\tpc\n"
  printf "  HP LaserJet 1\t192.168.111.200\tprinter123\tprinter\n"
  printf "  BIOS Иванов\t-\tqwerty456\tbios\n"
  echo ""

  printf "Иванов Иван\t192.168.111.5\tAdmin@2024\tpc\n" > "$PC_DB_PLAIN"
  chmod 600 "$PC_DB_PLAIN"

  echo -e "${CYAN}Отредактируй файл:${RESET} nano $PC_DB_PLAIN"
  echo -e "${CYAN}Затем зашифруй:${RESET}   pc --encrypt"
}

# ---------- зашифровать ----------
_encrypt() {
  if [[ ! -f "$PC_DB_PLAIN" ]]; then
    echo -e "${RED}Файл не найден:${RESET} $PC_DB_PLAIN"
    exit 1
  fi

  echo -e "${CYAN}Шифруем базу...${RESET}"
  echo -e "${YELLOW}Введи мастер-пароль:${RESET}"

  gpg --symmetric \
      --cipher-algo AES256 \
      --pinentry-mode loopback \
      --output "$PC_DB_ENC" \
      "$PC_DB_PLAIN"

  if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓ База зашифрована:${RESET} $PC_DB_ENC"
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

  gpg --decrypt \
      --pinentry-mode loopback \
      --output "$PC_DB_PLAIN" \
      "$PC_DB_ENC" 2>/dev/null

  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки. Неверный пароль?${RESET}"
    exit 1
  fi

  chmod 600 "$PC_DB_PLAIN"
  "${EDITOR:-nano}" "$PC_DB_PLAIN"

  echo -e "${CYAN}Сохраняем и шифруем обратно...${RESET}"
  echo -ne "${YELLOW}Введи мастер-пароль:${RESET} "
  read -rs MASTER_PASS
  echo ""
  
  if [[ -z "$MASTER_PASS" ]]; then
    echo -e "${RED}Пароль пустой - отмена. Файл не перезашифрован.${RESET}"
    shred -u "$PC_DB_PLAIN" 2>/dev/null || rm -f "$PC_DB_PLAIN"
    exit 1
  fi

  echo "$MASTER_PASS" | gpg --symmetric \
      --cipher-algo AES256 \
      --pinentry-mode loopback \
      --passphrase-fd 0 \
      --yes \
      --output "$PC_DB_ENC" \
      "$PC_DB_PLAIN"

  shred -u "$PC_DB_PLAIN" 2>/dev/null || rm -f "$PC_DB_PLAIN"
  echo -e "${GREEN}✓ База обновлена и зашифрована${RESET}"
}

# ---------- обработка аргументов ----------
setup_gpg_agent

case "$1" in
  --encrypt)
    _encrypt
    exit 0
    ;;
  --edit)
    _edit
    exit 0
    ;;
  --help|-h)
    echo ""
    echo -e "  ${BOLD}pc${RESET}           — открыть меню"
    echo -e "  ${BOLD}pc --edit${RESET}    — добавить/изменить записи"
    echo -e "  ${BOLD}pc --encrypt${RESET} — зашифровать plain TSV (первый раз)"
    echo ""
    exit 0
    ;;
esac

# ---------- первый запуск ----------
if [[ ! -f "$PC_DB_ENC" ]]; then
  _first_run
  exit 0
fi

# ---------- расшифровываем в память ----------
TSV_DATA=$(gpg_decrypt) || exit 1

# ---------- выбор категории ----------
CATEGORY=$(printf "▷  Сотрудники\n▷  Принтеры\n▷  BIOS\n▷  Notebook\n▷  Все" \
  | fzf \
      --prompt="  Категория > " \
      --height=30% \
      --reverse \
      --border=rounded \
      --color="prompt:yellow,pointer:green")

[[ -z "$CATEGORY" ]] && exit 0

case "$CATEGORY" in
  "▷  Сотрудники") FILTER="pc" ;;
  "▷  Принтеры")   FILTER="printer" ;;
  "▷  BIOS")       FILTER="bios" ;;
  "▷  Notebook")       FILTER="notebook" ;;
  *)                FILTER="" ;;
esac

# ---------- фильтруем по категории ----------
if [[ -n "$FILTER" ]]; then
  FILTERED=$(echo "$TSV_DATA" | grep -v '^\s*$' | awk -F'\t' -v f="$FILTER" '$4==f')
else
  FILTERED=$(echo "$TSV_DATA" | grep -v '^\s*$')
fi

if [[ -z "$FILTERED" ]]; then
  echo -e "${YELLOW}Нет записей в этой категории.${RESET}"
  exit 0
fi

# ---------- выбор записи ----------
SELECTED=$(echo "$FILTERED" \
  | awk -F'\t' '{printf "%-25s %-18s %s\n", $1, $2, $3}' \
  | fzf \
      --prompt="🖥  Поиск > " \
      --header="  Название                 IP                 Пароль" \
      --height=50% \
      --reverse \
      --border=rounded \
      --color="header:cyan,prompt:yellow,pointer:green")

[[ -z "$SELECTED" ]] && exit 0

# ---------- вытаскиваем данные ----------
ENTRY_KEY=$(echo "$SELECTED" | awk '{print $1}')
TSV_LINE=$(echo "$FILTERED" \
  | awk -F'\t' -v key="$ENTRY_KEY" 'index($1, key) {print; exit}')

NAME=$(echo "$TSV_LINE"     | cut -f1)
IP=$(echo "$TSV_LINE"       | cut -f2)
PASSWORD=$(echo "$TSV_LINE" | cut -f3)
TYPE=$(echo "$TSV_LINE"     | cut -f4)

# ---------- показываем данные ----------
echo ""
echo -e "  ${BOLD}${CYAN}Название:${RESET} $NAME"
echo -e "  ${BOLD}${CYAN}IP:${RESET}       $IP"
echo -e "  ${BOLD}${CYAN}Пароль:${RESET}   $PASSWORD"
echo ""

# ---------- меню действий (зависит от типа) ----------
if [[ "$TYPE" == "pc" ]]; then
  ACTIONS="▷  Скопировать пароль\n▷  Показать IP + пароль\n▷  SSH  →  $IP\n▷  RDP  →  $IP\n▷  Отмена"
else
  ACTIONS="▷  Скопировать пароль\n▷  Показать пароль\n▷  Отмена"
fi

ACTION=$(printf "$ACTIONS" \
  | fzf \
      --prompt="  Действие > " \
      --height=35% \
      --reverse \
      --border=rounded \
      --color="prompt:yellow,pointer:green")

case "$ACTION" in
  "▷  Скопировать пароль")
    _copy "$PASSWORD"
    ;;
  "▷  Показать IP + пароль"|"👁  Показать пароль")
    echo ""
    echo -e "  Название : ${BOLD}$NAME${RESET}"
    [[ "$IP" != "-" ]] && echo -e "  IP       : ${BOLD}${CYAN}$IP${RESET}"
    echo -e "  Пароль   : ${BOLD}${GREEN}$PASSWORD${RESET}"
    echo ""
    ;;
  "▷  SSH"*)
    echo -e "${CYAN}SSH → ${BOLD}$IP${RESET} (${NAME})..."
    sshpass -p "$PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      "${ADMIN_USER}@${IP}"
    ;;
  "▷  RDP"*)
    if command -v xfreerdp &>/dev/null; then
      echo -e "${CYAN}RDP → ${BOLD}$IP${RESET} (${NAME})..."
      xfreerdp /v:"$IP" /p:"$PASSWORD" /u:"$ADMIN_USER" /cert:ignore &
    elif command -v rdesktop &>/dev/null; then
      rdesktop -p "$PASSWORD" -u "$ADMIN_USER" "$IP" &
    else
      echo -e "${YELLOW}Установи xfreerdp:${RESET} sudo apt install freerdp2-x11"
    fi
    ;;
  *)
    echo -e "${YELLOW}Отмена.${RESET}"
    ;;
esac