#!/usr/bin/env bash
# ============================================================
#  passgen — генератор паролей для сотрудников
#  Хранение: отдельный зашифрованный GPG файл
#  Смена паролей: каждые 40 дней
#  Использование:
#    passgen            — показать список + предупреждения
#    passgen --new      — сгенерировать пароль для сотрудника
#    passgen --show     — найти и показать пароль
#    passgen --edit     — открыть базу для ручной правки
# ============================================================

DB_ENC="${HOME}/.config/pc/passwords.csv.gpg"
DB_PLAIN="${HOME}/.config/pc/passwords.csv"
CHANGE_DAYS=40
WARN_DAYS=7   # предупреждать за 7 дней до смены

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ---------- зависимости ----------
for cmd in fzf gpg openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Ошибка:${RESET} $cmd не установлен."
    exit 1
  fi
done

# ---------- gpg-agent без кэша ----------
_setup_gpg_agent() {
  local conf="${HOME}/.gnupg/gpg-agent.conf"
  mkdir -p "${HOME}/.gnupg" && chmod 700 "${HOME}/.gnupg"
  if ! grep -q "default-cache-ttl" "$conf" 2>/dev/null; then
    echo "default-cache-ttl 0" >> "$conf"
    echo "max-cache-ttl 0" >> "$conf"
    gpg-connect-agent reloadagent /bye &>/dev/null
  fi
}

# ---------- копирование в буфер ----------
_copy() {
  if command -v xclip &>/dev/null; then
    echo -n "$1" | xclip -selection clipboard
  elif command -v xsel &>/dev/null; then
    echo -n "$1" | xsel --clipboard --input
  fi
}

# ---------- генерация пароля ----------
# Гарантирует: минимум 1 заглавная, 1 строчная, 1 цифра, 1 спецсимвол, итого 15 символов
_gen_password() {
  python3 -c "
import random, string
upper   = random.choices(string.ascii_uppercase, k=3)
lower   = random.choices(string.ascii_lowercase, k=3)
digits  = random.choices(string.digits, k=3)
special = random.choices(list('!@#\$%^&*()_+='), k=3)
rest    = random.choices(string.ascii_letters + string.digits + '!@#\$%^&*()_+=', k=3)
pool    = upper + lower + digits + special + rest
random.shuffle(pool)
print(''.join(pool[:15]))
"
}

# ---------- расшифровать в переменную ----------
_decrypt() {
  gpg --decrypt "$DB_ENC" 2>/dev/null
}

# ---------- зашифровать из файла ----------
_encrypt_file() {
  gpg --symmetric \
      --cipher-algo AES256 \
      --batch --yes \
      --output "$DB_ENC" \
      "$DB_PLAIN"
  local rc=$?
  shred -u "$DB_PLAIN" 2>/dev/null || rm -f "$DB_PLAIN"
  return $rc
}

# ---------- дней до смены ----------
_days_until_change() {
  local generated="$1"
  local now
  now=$(date +%s)
  local gen_ts
  gen_ts=$(date -d "$generated" +%s 2>/dev/null)
  if [[ -z "$gen_ts" ]]; then echo "?"; return; fi
  local diff=$(( (now - gen_ts) / 86400 ))
  echo $(( CHANGE_DAYS - diff ))
}

# ---------- первый запуск ----------
_first_run() {
  mkdir -p "$(dirname "$DB_PLAIN")"
  echo -e "${YELLOW}Первый запуск — создаём базу паролей.${RESET}"
  echo ""
  echo "employee,password,generated,change_by" > "$DB_PLAIN"
  chmod 600 "$DB_PLAIN"

  echo -e "${CYAN}Шифруем базу...${RESET}"
  echo -e "${YELLOW}Введи мастер-пароль для базы паролей:${RESET}"
  gpg --symmetric --cipher-algo AES256 --output "$DB_ENC" "$DB_PLAIN"
  shred -u "$DB_PLAIN" 2>/dev/null || rm -f "$DB_PLAIN"
  echo -e "${GREEN}✓ База создана:${RESET} $DB_ENC"
  echo ""
  echo -e "Теперь запусти ${BOLD}passgen --new${RESET} чтобы добавить первого сотрудника."
}

# ---------- --new: новый пароль ----------
_new() {
  local csv
  csv=$(_decrypt)
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки.${RESET}"; exit 1
  fi

  # Выбираем сотрудника через fzf (из существующих) или вводим вручную
  echo -e "${CYAN}Введи имя сотрудника (или выбери из существующих):${RESET}"

  local existing
  existing=$(echo "$csv" | tail -n +2 | grep -v '^\s*$' | cut -d',' -f1)

  local employee
  if [[ -n "$existing" ]]; then
    employee=$(printf "%s\n[+ Новый сотрудник]" "$existing" \
      | fzf --prompt="  Сотрудник > " \
            --height=40% --reverse --border=rounded \
            --color="prompt:yellow,pointer:green")
  fi

  if [[ -z "$employee" ]] || [[ "$employee" == "[+ Новый сотрудник]" ]]; then
    echo -ne "  Имя сотрудника: "
    read -r employee
  fi

  [[ -z "$employee" ]] && echo -e "${YELLOW}Отмена.${RESET}" && exit 0

  # Генерируем пароль
  local password
  password=$(_gen_password)
  local generated
  generated=$(date '+%Y-%m-%d')
  local change_by
  change_by=$(date -d "+${CHANGE_DAYS} days" '+%Y-%m-%d')

  # Показываем сотруднику
  echo ""
  echo -e "  ┌─────────────────────────────────────┐"
  echo -e "  │  Сотрудник : ${BOLD}$employee${RESET}"
  echo -e "  │  Пароль    : ${BOLD}${GREEN}$password${RESET}"
  echo -e "  │  Выдан     : $generated"
  echo -e "  │  Сменить до: ${YELLOW}$change_by${RESET}"
  echo -e "  └─────────────────────────────────────┘"
  echo ""
  _copy "$password"
  echo -e "  ${GREEN}✓ Пароль скопирован в буфер${RESET}"
  echo ""
  echo -e "  ${YELLOW}Сотрудник записывает пароль...${RESET}"
  echo -ne "  Нажми Enter когда готово: "
  read -r

  # Сохраняем в базу (удаляем старую запись если есть, добавляем новую)
  echo "$csv" > "$DB_PLAIN"
  # Удаляем старую запись этого сотрудника если есть
  grep -v "^${employee}," "$DB_PLAIN" > "${DB_PLAIN}.tmp" && mv "${DB_PLAIN}.tmp" "$DB_PLAIN"
  # Добавляем новую
  echo "${employee},${password},${generated},${change_by}" >> "$DB_PLAIN"
  chmod 600 "$DB_PLAIN"

  echo -e "${CYAN}Сохраняем...${RESET}"
  _encrypt_file
  echo -e "${GREEN}✓ Записано в базу${RESET}"
}

# ---------- --show: найти пароль ----------
_show() {
  local csv
  csv=$(_decrypt)
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки.${RESET}"; exit 1
  fi

  local selected
  selected=$(echo "$csv" \
    | tail -n +2 | grep -v '^\s*$' \
    | awk -F',' '{printf "%-25s %-15s сменить до: %s\n", $1, $2, $4}' \
    | fzf --prompt="🔑  Поиск > " \
          --header="  Сотрудник                Пароль          Срок" \
          --height=50% --reverse --border=rounded \
          --color="header:cyan,prompt:yellow,pointer:green")

  [[ -z "$selected" ]] && exit 0

  local emp_key
  emp_key=$(echo "$selected" | awk '{print $1}')
  local line
  line=$(echo "$csv" | tail -n +2 | awk -F',' -v k="$emp_key" 'index($1,k){print;exit}')

  local employee password generated change_by
  employee=$(echo "$line" | cut -d',' -f1 | xargs)
  password=$(echo "$line" | cut -d',' -f2 | xargs)
  generated=$(echo "$line" | cut -d',' -f3 | xargs)
  change_by=$(echo "$line" | cut -d',' -f4 | xargs)

  local days_left
  days_left=$(_days_until_change "$generated")

  echo ""
  echo -e "  Сотрудник : ${BOLD}$employee${RESET}"
  echo -e "  Пароль    : ${BOLD}${GREEN}$password${RESET}"
  echo -e "  Выдан     : $generated"

  if [[ "$days_left" =~ ^[0-9]+$ ]] && (( days_left <= 0 )); then
    echo -e "  Сменить до: ${RED}${BOLD}$change_by (просрочен!)${RESET}"
  elif [[ "$days_left" =~ ^[0-9]+$ ]] && (( days_left <= WARN_DAYS )); then
    echo -e "  Сменить до: ${YELLOW}${BOLD}$change_by (осталось ${days_left} дн.)${RESET}"
  else
    echo -e "  Сменить до: $change_by (осталось ${days_left} дн.)"
  fi
  echo ""

  _copy "$password"
  echo -e "  ${GREEN}✓ Пароль скопирован в буфер${RESET}"
  echo ""
}

# ---------- главный экран: список с предупреждениями ----------
_list() {
  local csv
  csv=$(_decrypt)
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки.${RESET}"; exit 1
  fi

  local count=0
  local warn=0

  echo ""
  echo -e "  ${BOLD}${CYAN}База паролей сотрудников${RESET}"
  echo -e "  ─────────────────────────────────────────────────"
  printf "  %-25s %-12s %-12s %s\n" "Сотрудник" "Выдан" "Сменить до" "Статус"
  echo -e "  ─────────────────────────────────────────────────"

  while IFS=',' read -r employee password generated change_by; do
    [[ "$employee" == "employee" ]] && continue
    [[ -z "$employee" ]] && continue

    local days_left
    days_left=$(_days_until_change "$generated")
    local status=""

    if [[ "$days_left" =~ ^[0-9]+$ ]] && (( days_left <= 0 )); then
      status="${RED}● просрочен${RESET}"
      (( warn++ ))
    elif [[ "$days_left" =~ ^[0-9]+$ ]] && (( days_left <= WARN_DAYS )); then
      status="${YELLOW}● ${days_left} дн.${RESET}"
      (( warn++ ))
    else
      status="${GREEN}● ok${RESET}"
    fi

    printf "  %-25s %-12s %-12s " "$employee" "$generated" "$change_by"
    echo -e "$status"
    (( count++ ))
  done <<< "$(echo "$csv" | tail -n +2 | grep -v '^\s*$')"

  echo -e "  ─────────────────────────────────────────────────"
  echo -e "  Всего: ${BOLD}$count${RESET} сотрудников"
  if (( warn > 0 )); then
    echo -e "  ${YELLOW}⚠ Требуют смены: ${BOLD}$warn${RESET}"
  fi
  echo ""
}

# ---------- --edit ----------
_edit() {
  local csv
  csv=$(_decrypt)
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка расшифровки.${RESET}"; exit 1
  fi

  echo "$csv" > "$DB_PLAIN"
  chmod 600 "$DB_PLAIN"
  "${EDITOR:-nano}" "$DB_PLAIN"

  _encrypt_file
  echo -e "${GREEN}✓ База обновлена${RESET}"
}

# ---------- точка входа ----------
_setup_gpg_agent

if [[ ! -f "$DB_ENC" ]]; then
  _first_run
  exit 0
fi

case "$1" in
  --new)   _new ;;
  --show)  _show ;;
  --edit)  _edit ;;
  --help|-h)
    echo ""
    echo -e "  ${BOLD}passgen${RESET}         — список всех паролей и статус"
    echo -e "  ${BOLD}passgen --new${RESET}   — выдать новый пароль сотруднику"
    echo -e "  ${BOLD}passgen --show${RESET}  — найти и показать пароль"
    echo -e "  ${BOLD}passgen --edit${RESET}  — редактировать базу вручную"
    echo ""
    ;;
  *)       _list ;;
esac
