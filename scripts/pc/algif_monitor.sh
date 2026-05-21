#!/usr/bin/env bash
# ============================================================
#  algif_monitor — мониторинг и дообработка офлайн машин
#  Запускать после fix_algif для автоматической обработки
#  машин которые были офлайн
#
#  Использование:
#    algif_monitor           — запустить мониторинг
#    algif_monitor --status  — показать текущий статус
# ============================================================

PC_DB_ENC="${HOME}/.config/pc/computers.csv.gpg"
ADMIN_USER="administrator"
SSH_TIMEOUT=5
PING_INTERVAL=60   # проверять каждые N секунд

LOG_DIR="${HOME}/.config/pc/algif"
DONE_LOG="${LOG_DIR}/done.log"
PENDING_LOG="${LOG_DIR}/pending.log"
MONITOR_LOG="${LOG_DIR}/monitor.log"
PID_FILE="${LOG_DIR}/monitor.pid"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

REMOTE_CMD='
set -e
echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
rmmod algif_aead 2>/dev/null || true
if grep -q "algif_aead" /etc/modprobe.d/disable-algif.conf; then
  echo "OK"
else
  echo "FAIL"
  exit 1
fi
'

HAS_SSHPASS=false
command -v sshpass &>/dev/null && HAS_SSHPASS=true

# ---------- инициализация ----------
_init() {
  mkdir -p "$LOG_DIR"
  touch "$DONE_LOG" "$PENDING_LOG" "$MONITOR_LOG"
}

# ---------- запись в лог ----------
_log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$MONITOR_LOG"
}

# ---------- уже обработана? ----------
_is_done() {
  local ip="$1"
  grep -q "^$ip," "$DONE_LOG" 2>/dev/null
}

# ---------- применить фикс ----------
_apply_fix() {
  local ip="$1" password="$2"

  if [[ "$HAS_SSHPASS" == "true" ]]; then
    result=$(sshpass -p "$password" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o BatchMode=no \
      -o LogLevel=ERROR \
      "${ADMIN_USER}@${ip}" \
      "echo '$password' | sudo -S bash -c '$REMOTE_CMD'" 2>/dev/null)
  else
    result=$(ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      -o BatchMode=no \
      -o LogLevel=ERROR \
      "${ADMIN_USER}@${ip}" \
      "sudo bash -c '$REMOTE_CMD'" 2>/dev/null)
  fi

  echo "$result"
}

# ---------- --status: показать текущее состояние ----------
_status() {
  _init

  echo ""
  echo -e "  ${BOLD}${CYAN}Статус устранения algif_aead${RESET}"
  echo ""

  # Обработанные машины
  local done_count=0
  if [[ -s "$DONE_LOG" ]]; then
    echo -e "  ${GREEN}${BOLD}✓ Обработано:${RESET}"
    while IFS=',' read -r ip employee ts; do
      printf "  ${GREEN}✓${RESET}  %-20s %-25s %s\n" "$ip" "$employee" "$ts"
      (( done_count++ ))
    done < "$DONE_LOG"
  else
    echo -e "  ${GREEN}✓ Обработано:${RESET} нет записей"
  fi

  echo ""

  # Ожидающие машины
  local pending_count=0
  if [[ -s "$PENDING_LOG" ]]; then
    echo -e "  ${YELLOW}${BOLD}⏳ Ожидают обработки:${RESET}"
    while IFS=',' read -r ip employee; do
      # Проверяем онлайн ли сейчас
      if ping -c 1 -W 1 "$ip" &>/dev/null; then
        printf "  ${YELLOW}⏳${RESET}  %-20s %-25s ${GREEN}(онлайн сейчас!)${RESET}\n" "$ip" "$employee"
      else
        printf "  ${YELLOW}⏳${RESET}  %-20s %-25s ${RED}(офлайн)${RESET}\n" "$ip" "$employee"
      fi
      (( pending_count++ ))
    done < "$PENDING_LOG"
  else
    echo -e "  ${YELLOW}⏳ Ожидают обработки:${RESET} нет — все машины обработаны!"
  fi

  echo ""
  echo -e "  ──────────────────────────────────"
  echo -e "  ${GREEN}Готово:${RESET}  $done_count"
  echo -e "  ${YELLOW}Pending:${RESET} $pending_count"
  echo ""

  # Статус монитора
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo -e "  ${GREEN}● Мониторинг запущен${RESET} (PID $pid)"
    else
      echo -e "  ${RED}● Мониторинг не запущен${RESET} (был PID $pid)"
      rm -f "$PID_FILE"
    fi
  else
    echo -e "  ${RED}● Мониторинг не запущен${RESET}"
    if [[ -s "$PENDING_LOG" ]]; then
      echo -e "  ${YELLOW}  Запусти ${BOLD}algif_monitor${RESET}${YELLOW} чтобы автоматически обработать оставшиеся машины${RESET}"
    fi
  fi
  echo ""
}

# ---------- основной цикл мониторинга ----------
_monitor_loop() {
  local csv_data="$1"

  _log "INFO" "Мониторинг запущен (PID $$, интервал ${PING_INTERVAL}с)"
  echo $$ > "$PID_FILE"

  # Заполняем pending.log машинами которые ещё не обработаны
  while IFS=',' read -r employee ip password; do
    [[ "$employee" == "employee" ]] && continue
    [[ -z "$ip" ]] && continue
    employee=$(echo "$employee" | xargs)
    ip=$(echo "$ip" | xargs)

    if ! _is_done "$ip"; then
      # Добавляем в pending если ещё нет
      if ! grep -q "^$ip," "$PENDING_LOG" 2>/dev/null; then
        echo "${ip},${employee}" >> "$PENDING_LOG"
        _log "INFO" "Добавлен в очередь: $employee ($ip)"
      fi
    fi
  done <<< "$(echo "$csv_data" | grep -v '^\s*$')"

  local pending_count
  pending_count=$(grep -c '.' "$PENDING_LOG" 2>/dev/null || echo 0)
  _log "INFO" "Машин в очереди: $pending_count"

  # Основной цикл
  while true; do
    # Перечитываем pending каждую итерацию
    local remaining=()
    while IFS=',' read -r ip employee; do
      [[ -z "$ip" ]] && continue
      remaining+=("${ip},${employee}")
    done < "$PENDING_LOG"

    if [[ ${#remaining[@]} -eq 0 ]]; then
      _log "INFO" "Все машины обработаны! Мониторинг завершён."
      rm -f "$PID_FILE" "$PENDING_LOG"
      echo -e "\n  ${GREEN}✓ Все машины обработаны! Мониторинг завершён.${RESET}\n"
      exit 0
    fi

    for entry in "${remaining[@]}"; do
      local ip employee password
      ip=$(echo "$entry" | cut -d',' -f1)
      employee=$(echo "$entry" | cut -d',' -f2)

      # Берём пароль из CSV
      password=$(echo "$csv_data" | awk -F',' -v i="$ip" '$2==i{print $3; exit}' | xargs)

      # Пингуем
      if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
        continue  # офлайн — пропускаем до следующей итерации
      fi

      _log "INFO" "Машина онлайн: $employee ($ip) — применяем фикс..."
      echo -e "  ${CYAN}→ Онлайн:${RESET} ${BOLD}$employee${RESET} ($ip) — применяем фикс..."

      result=$(_apply_fix "$ip" "$password")

      if [[ "$result" == "OK" ]]; then
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        # Добавляем в done.log
        echo "${ip},${employee},${ts}" >> "$DONE_LOG"
        # Удаляем из pending.log
        grep -v "^${ip}," "$PENDING_LOG" > "${PENDING_LOG}.tmp" && \
          mv "${PENDING_LOG}.tmp" "$PENDING_LOG"

        _log "OK" "$employee ($ip) — успешно"
        echo -e "  ${GREEN}✓ Готово:${RESET} ${BOLD}$employee${RESET} ($ip)"
      else
        _log "WARN" "$employee ($ip) — ошибка: $result"
        echo -e "  ${RED}✗ Ошибка:${RESET} $employee ($ip): $result"
      fi
    done

    sleep "$PING_INTERVAL"
  done
}

# ---------- точка входа ----------
_init

case "$1" in
  --status)
    _status
    exit 0
    ;;
  --stop)
    if [[ -f "$PID_FILE" ]]; then
      pid=$(cat "$PID_FILE")
      if kill "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        echo -e "${GREEN}✓ Мониторинг остановлен (PID $pid)${RESET}"
      else
        echo -e "${YELLOW}Процесс не найден.${RESET}"
        rm -f "$PID_FILE"
      fi
    else
      echo -e "${YELLOW}Мониторинг не запущен.${RESET}"
    fi
    exit 0
    ;;
  --help|-h)
    echo ""
    echo -e "  ${BOLD}algif_monitor${RESET}           — запустить мониторинг"
    echo -e "  ${BOLD}algif_monitor --status${RESET}  — показать статус"
    echo -e "  ${BOLD}algif_monitor --stop${RESET}    — остановить мониторинг"
    echo ""
    exit 0
    ;;
esac

# Проверяем не запущен ли уже
if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "${YELLOW}Мониторинг уже запущен (PID $pid)${RESET}"
    echo -e "Для статуса: ${BOLD}algif_monitor --status${RESET}"
    exit 0
  fi
fi

# Расшифровываем базу
if [[ ! -f "$PC_DB_ENC" ]]; then
  echo -e "${RED}База pc не найдена.${RESET}"
  exit 1
fi

echo -e "${CYAN}Расшифровываем базу pc...${RESET}"
CSV_DATA=$(gpg --decrypt "$PC_DB_ENC" 2>/dev/null)
if [[ $? -ne 0 ]] || [[ -z "$CSV_DATA" ]]; then
  echo -e "${RED}Ошибка расшифровки.${RESET}"
  exit 1
fi

echo ""
echo -e "  ${BOLD}${CYAN}algif_monitor запущен${RESET}"
echo -e "  Проверка каждые ${BOLD}${PING_INTERVAL}с${RESET}"
echo -e "  Статус: ${BOLD}algif_monitor --status${RESET}"
echo -e "  Стоп:   ${BOLD}algif_monitor --stop${RESET}"
echo -e "  Лог:    ${BOLD}$MONITOR_LOG${RESET}"
echo ""

# Запускаем в фоне
_monitor_loop "$CSV_DATA" &
disown

echo -e "  ${GREEN}● Мониторинг запущен в фоне (PID $!)${RESET}"
echo ""
