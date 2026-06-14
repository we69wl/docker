#!/usr/bin/env bash
# ============================================================
#  fix_algif — массовое устранение уязвимости algif_aead
#  Читает базу pc, подключается по SSH к каждой машине,
#  блокирует загрuzку модуля algif_aead
#  Использование: fix_algif
# ============================================================

PC_DB_ENC="${HOME}/.config/pc/computers.tsv.gpg"

# Логин локального админа — поменяй на свой
ADMIN_USER="administrator"

# Таймаут подключения SSH в секундах
SSH_TIMEOUT=5

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

LOG_FILE="${HOME}/.config/pc/logs/fix_algif_$(date '+%Y-%m-%d_%H-%M').log"

# ---------- команды которые нужно выполнить на каждой машине ----------
REMOTE_CMD='
set -e
# 1. Блокируем модуль через modprobe
echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf

# 2. Выгружаем модуль если он сейчас загружен (ошибку игнорируем)
rmmod algif_aead 2>/dev/null || true

# 3. Проверяем что файл создан
if grep -q "algif_aead" /etc/modprobe.d/disable-algif.conf; then
  echo "OK"
else
  echo "FAIL"
  exit 1
fi
'

# ---------- проверка зависимостей ----------
if ! command -v gpg &>/dev/null; then
  echo -e "${RED}Ошибка:${RESET} gpg не установлен."
  exit 1
fi

if ! command -v ssh &>/dev/null; then
  echo -e "${RED}Ошибка:${RESET} ssh не установлен."
  exit 1
fi

HAS_SSHPASS=false
if command -v sshpass &>/dev/null; then
  HAS_SSHPASS=true
else
  echo -e "${YELLOW}⚠ sshpass не найден.${RESET}"
  echo -e "  Для автоматической передачи пароля установи его:"
  echo -e "  ${BOLD}sudo apt install sshpass${RESET}"
  echo ""
  echo -e "  Без sshpass скрипт попробует подключиться без пароля (SSH-ключ или sudo без пароля)."
  echo -e "  Если не получится — машина будет помечена как SKIP."
  echo ""
  read -r -p "  Продолжить без sshpass? (y/n): " confirm
  [[ "$confirm" != "y" ]] && exit 0
fi

# ---------- проверка базы ----------
if [[ ! -f "$PC_DB_ENC" ]]; then
  echo -e "${RED}База pc не найдена:${RESET} $PC_DB_ENC"
  echo "Сначала настрой pc и заполни базу."
  exit 1
fi

# ---------- расшифровываем базу ----------
echo -e "${CYAN}Расшифровываем базу pc...${RESET}"
TSV_DATA=$(gpg --decrypt "$PC_DB_ENC" 2>/dev/null)
if [[ $? -ne 0 ]] || [[ -z "$TSV_DATA" ]]; then
  echo -e "${RED}Ошибка расшифровки. Неверный мастер-пароль?${RESET}"
  exit 1
fi

# ---------- счётчики ----------
total=0
success=0
failed=0
skipped=0
offline=0

mkdir -p "$(dirname "$LOG_FILE")"
echo "fix_algif — $(date)" > "$LOG_FILE"
echo "======================================" >> "$LOG_FILE"

echo ""
echo -e "${BOLD}${CYAN}  Устранение уязвимости algif_aead${RESET}"
echo -e "  ──────────────────────────────────────────────────────"
printf "  %-25s %-18s %s\n" "Сотрудник" "IP" "Статус"
echo -e "  ──────────────────────────────────────────────────────"

# ---------- SSH-опции ----------
SSH_OPTS=(
  -o "StrictHostKeyChecking=no"
  -o "ConnectTimeout=${SSH_TIMEOUT}"
  -o BatchMode=no
  -o LogLevel=ERROR
)

# ---------- основной цикл ----------
while IFS=$'\t' read -r employee ip password type; do
  # Пропускаем заголовок и пустые строки
  [[ "$employee" == "employee" ]] && continue
  [[ -z "$ip" ]] && continue
  [[ "$type" != "pc" ]] && continue
  employee=$(echo "$employee")
  ip=$(echo "$ip")
  password=$(echo "$password")

  (( total++ ))

  # Проверяем доступность машины
  if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
    printf "  %-25s %-18s " "$employee" "$ip"
    echo -e "${YELLOW}● офлайн${RESET}"
    echo "OFFLINE: $employee ($ip)" >> "$LOG_FILE"
    (( offline++ ))
    continue
  fi

  # Функция выполнения команды
  _run_remote() {
    local stdin_data
    stdin_data="$password
  $REMOTE_CMD"

    if [[ "$HAS_SSHPASS" == "true" ]]; then
        # "echo '$password' | sudo -S bash -c '$REMOTE_CMD'" < /dev/null
      sshpass -p "$password" ssh "${SSH_OPTS[@]}" \
        "${ADMIN_USER}@${ip}" \
        "/usr/bin/sudo -S /bin/bash -s" <<< "$stdin_data"
    else
      ssh "${SSH_OPTS[@]}" \
        "${ADMIN_USER}@${ip}" \
        "/usr/bin/sudo /bin/bash -s" <<< "$REMOTE_CMD" 2>/dev/null
    fi
  }

  printf "  %-25s %-18s " "$employee" "$ip"

  result=$(_run_remote true)

  if [[ "$result" == "OK" ]]; then
    echo -e "${GREEN}● готово${RESET}"
    echo "OK: $employee ($ip)" >> "$LOG_FILE"
    (( success++ ))
  elif [[ -z "$result" ]]; then
    echo -e "${RED}● нет доступа (SSH/пароль)${RESET}"
    echo "NO_ACCESS: $employee ($ip)" >> "$LOG_FILE"
    (( skipped++ ))
  else
    echo -e "${RED}● ошибка: $result${RESET}"
    echo "FAIL: $employee ($ip) — $result" >> "$LOG_FILE"
    (( failed++ ))
  fi

done <<< "$(echo "$TSV_DATA" | grep -v '^\s*$')"

# ---------- итог ----------
echo -e "  ──────────────────────────────────────────────────────"
echo ""
echo -e "  ${BOLD}Итог:${RESET}"
echo -e "  Всего машин в базе : ${BOLD}$total${RESET}"
echo -e "  ${GREEN}✓ Успешно           : $success${RESET}"
echo -e "  ${YELLOW}● Офлайн            : $offline${RESET}"
echo -e "  ${RED}✗ Нет доступа       : $skipped${RESET}"
echo -e "  ${RED}✗ Ошибка            : $failed${RESET}"
echo ""
echo -e "  Лог сохранён: ${BOLD}$LOG_FILE${RESET}"
echo ""

# ---------- напоминание про офлайн машины ----------
if (( offline > 0 )); then
  echo -e "  ${YELLOW}⚠ $offline машин были офлайн — не забудь обработать их вручную когда появятся в сети.${RESET}"
  echo ""
fi

