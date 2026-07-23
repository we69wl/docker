#!/usr/bin/env bash
# ============================================================
#  algif_monitor — мониторинг и дообработка офлайн машин
#  Запускать после fix_algif для автоматической обработки
#  машин которые были офлайн
#
#  Использование:
#    algif_monitor           — запустить мониторинг
#    algif_monitor --status  — показать текущий статус
#    algif_monitor --stop    — остановить мониторинг
# ============================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PING_INTERVAL=60

LOG_DIR="${HOME}/.config/pc/algif"
DONE_LOG="${LOG_DIR}/done.log"
PENDING_LOG="${LOG_DIR}/pending.log"
LOG_FILE="${LOG_DIR}/monitor.log"   # используется функцией log() из common.sh
PID_FILE="${LOG_DIR}/monitor.pid"

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

_init() {
  mkdir -p "$LOG_DIR"
  touch "$DONE_LOG" "$PENDING_LOG" "$LOG_FILE"
}

_is_done() {
  grep -q "^$1," "$DONE_LOG" 2>/dev/null
}

# ---------- --status ----------
_status() {
  _init
  echo ""
  echo -e "  ${BOLD}${CYAN}Статус устранения algif_aead${RESET}"
  echo ""

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

  local pending_count=0
  if [[ -s "$PENDING_LOG" ]]; then
    echo -e "  ${YELLOW}${BOLD}⏳ Ожидают обработки:${RESET}"
    while IFS=',' read -r ip employee; do
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

# ---------- основной цикл ----------
_monitor_loop() {
  local tsv_data="$1"

  log INFO "Мониторинг запущен (PID $$, интервал ${PING_INTERVAL}с)"
  echo $$ > "$PID_FILE"

  # Заполняем pending.log машинами которые ещё не обработаны (только тип pc)
  while IFS=$'\t' read -r employee ip password type; do
    [[ "$employee" == "employee" ]] && continue
    [[ -z "$ip" || "$ip" == "-" ]] && continue
    [[ "$type" != "pc" ]] && continue

    if ! _is_done "$ip"; then
      if ! grep -q "^$ip," "$PENDING_LOG" 2>/dev/null; then
        echo "${ip},${employee}" >> "$PENDING_LOG"
        log INFO "Добавлен в очередь: $employee ($ip)"
      fi
    fi
  done <<< "$(echo "$tsv_data" | grep -v '^\s*$')"

  local pending_count
  pending_count=$(grep -c '.' "$PENDING_LOG" 2>/dev/null || echo 0)
  log INFO "Машин в очереди: $pending_count"

  while true; do
    local remaining=()
    while IFS=',' read -r ip employee; do
      [[ -z "$ip" ]] && continue
      remaining+=("${ip},${employee}")
    done < "$PENDING_LOG"

    if [[ ${#remaining[@]} -eq 0 ]]; then
      log INFO "Все машины обработаны! Мониторинг завершён."
      rm -f "$PID_FILE" "$PENDING_LOG"
      echo -e "\n  ${GREEN}✓ Все машины обработаны! Мониторинг завершён.${RESET}\n"
      exit 0
    fi

    for entry in "${remaining[@]}"; do
      local ip employee password
      ip=$(echo "$entry" | cut -d',' -f1)
      employee=$(echo "$entry" | cut -d',' -f2)

      # Берём пароль из TSV-базы (3-я колонка)
      password=$(echo "$tsv_data" | awk -F'\t' -v i="$ip" '$2==i{print $3; exit}')

      if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
        continue
      fi

      log INFO "Машина онлайн: $employee ($ip) — применяем фикс..."
      echo -e "  ${CYAN}→ Онлайн:${RESET} ${BOLD}$employee${RESET} ($ip) — применяем фикс..."

      result=$(ssh_run "$ip" "$password" <<< "$REMOTE_CMD")

      if [[ "$result" == "OK" ]]; then
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "${ip},${employee},${ts}" >> "$DONE_LOG"
        grep -v "^${ip}," "$PENDING_LOG" > "${PENDING_LOG}.tmp" && \
          mv "${PENDING_LOG}.tmp" "$PENDING_LOG"
        log OK "$employee ($ip) — успешно"
        echo -e "  ${GREEN}✓ Готово:${RESET} ${BOLD}$employee${RESET} ($ip)"
      else
        log WARN "$employee ($ip) — ошибка: $result"
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

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "${YELLOW}Мониторинг уже запущен (PID $pid)${RESET}"
    echo -e "Для статуса: ${BOLD}algif_monitor --status${RESET}"
    exit 0
  fi
fi

if [[ ! -f "$PC_DB_ENC" ]]; then
  echo -e "${RED}База pc не найдена.${RESET}"
  exit 1
fi

echo -e "${CYAN}Расшифровываем базу pc...${RESET}"
TSV_DATA=$(gpg_decrypt) || exit 1

echo ""
echo -e "  ${BOLD}${CYAN}algif_monitor запущен${RESET}"
echo -e "  Проверка каждые ${BOLD}${PING_INTERVAL}с${RESET}"
echo -e "  Статус: ${BOLD}algif_monitor --status${RESET}"
echo -e "  Стоп:   ${BOLD}algif_monitor --stop${RESET}"
echo -e "  Лог:    ${BOLD}$LOG_FILE${RESET}"
echo ""

_monitor_loop "$TSV_DATA" &
disown

echo -e "  ${GREEN}● Мониторинг запущен в фоне (PID $!)${RESET}"
echo ""
