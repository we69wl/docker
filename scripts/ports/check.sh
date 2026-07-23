#!/bin/bash
# =============================================================
# check_ports.sh — проверка доступности IP:порт через nmap
#
# Использование:
#   1. Заполните targets.txt (должен лежать рядом со скриптом)
#   2. chmod +x check_ports.sh
#   3. sudo ./check_ports.sh
#   4. Отчёт сохранится в report_ДАТА.txt
#
# Формат targets.txt (одна запись на строку):
#   IP   PROTO   PORT   ОПИСАНИЕ
#   Пустые строки и строки с # игнорируются.
#   PROTO: tcp | udp | both
#   PORT:  одиночный (443) или диапазон (20000-40000)
# =============================================================

TARGETS_FILE="${1:-$(dirname "$0")/targets.txt}"
TIMEOUT=5
# REPORT="report_$(date +%Y%m%d_%H%M%S).txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"

GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; NC='\033[0m'

if ! command -v nmap &>/dev/null; then
  echo "ОШИБКА: nmap не установлен."
  echo "  Ubuntu/Debian: sudo apt install nmap"
  echo "  RHEL/CentOS:   sudo yum install nmap"
  exit 1
fi

if [ ! -f "$TARGETS_FILE" ]; then
  echo "ОШИБКА: файл не найден: $TARGETS_FILE"
  echo "Использование: $0 [путь/к/targets.txt]"
  exit 1
fi

IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true

if ! $IS_ROOT; then
  echo -e "${YELLOW}ВНИМАНИЕ: запуск без sudo. UDP-проверки будут менее точны.${NC}"
  echo -e "${YELLOW}Рекомендуется: sudo ./check_ports.sh${NC}\n"
fi

TOTAL_HOSTS=0; OPEN_COUNT=0; CLOSED_COUNT=0; UNKNOWN_COUNT=0
declare -a CLOSED_LIST

check_host() {
  local IP=$1 PROTO=$2 PORTS=$3 DESC=$4

  TOTAL_HOSTS=$((TOTAL_HOSTS + 1))

  local SCAN_FLAGS="-Pn --host-timeout ${TIMEOUT}s"
  case $PROTO in
    tcp)  SCAN_FLAGS="$SCAN_FLAGS -sT" ;;
    udp)  SCAN_FLAGS="$SCAN_FLAGS -sU" ;;
    both) SCAN_FLAGS="$SCAN_FLAGS -sT -sU" ;;
  esac

  printf "%-18s %-5s %-16s %-20s ... " "$IP" "$PROTO" "$PORTS" "$DESC"

  local NMAP_OUT
  NMAP_OUT=$(nmap $SCAN_FLAGS -p "$PORTS" "$IP" 2>/dev/null)

  # TCP: только явно open
  local OPEN_TCP
  OPEN_TCP=$(echo "$NMAP_OUT" | grep -cE "[0-9]+/tcp[[:space:]]+open[[:space:]]")

  # UDP: open или open|filtered — оба считаем как открытый
  # (UDP не подтверждает соединение, open|filtered — норма)
  local OPEN_UDP
  OPEN_UDP=$(echo "$NMAP_OUT" | grep -cE "[0-9]+/udp[[:space:]]+open")

  # Явно закрытые/заблокированные
  local CLOSED_TCP
  CLOSED_TCP=$(echo "$NMAP_OUT" | grep -cE "[0-9]+/tcp[[:space:]]+(closed|filtered)")
  local CLOSED_UDP
  CLOSED_UDP=$(echo "$NMAP_OUT" | grep -cE "[0-9]+/udp[[:space:]]+closed")

  local TOTAL_OPEN=$(( OPEN_TCP + OPEN_UDP ))
  local TOTAL_CLOSED=$(( CLOSED_TCP + CLOSED_UDP ))

  local HAS_UDP_FILTERED=false
  echo "$NMAP_OUT" | grep -qE "[0-9]+/udp[[:space:]]+open\|filtered" && HAS_UDP_FILTERED=true

  if [ "$TOTAL_OPEN" -gt 0 ]; then
    if $HAS_UDP_FILTERED; then
      echo -e "${GREEN}ОТКРЫТ ✓${NC} ${YELLOW}(UDP: open|filtered — вероятно открыт, точный ответ не гарантирован)${NC}"
    else
      echo -e "${GREEN}ОТКРЫТО портов: $TOTAL_OPEN ✓${NC}"
    fi
    OPEN_COUNT=$((OPEN_COUNT + 1))
    printf "ОТКРЫТ    | %-18s | %-5s | %-16s | %s\n" \
      "$IP" "$PROTO" "$PORTS" "$DESC" >> "$REPORT"
  elif [ "$TOTAL_CLOSED" -gt 0 ]; then
    echo -e "${RED}ЗАКРЫТ/ФИЛЬТРУЕТСЯ ✗${NC}"
    CLOSED_COUNT=$((CLOSED_COUNT + 1))
    CLOSED_LIST+=("$IP  $PROTO/$PORTS  ($DESC)")
    printf "ЗАКРЫТ    | %-18s | %-5s | %-16s | %s\n" \
      "$IP" "$PROTO" "$PORTS" "$DESC" >> "$REPORT"
  else
    echo -e "${YELLOW}НЕИЗВЕСТНО ? (хост не ответил — уточнить у эксперта)${NC}"
    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
    CLOSED_LIST+=("$IP  $PROTO/$PORTS  ($DESC)  [?неизвестно]")
    printf "НЕИЗВЕСТНО| %-18s | %-5s | %-16s | %s\n" \
      "$IP" "$PROTO" "$PORTS" "$DESC" >> "$REPORT"
  fi
}

HEADER="Отчёт проверки доступности IP:Порт (nmap)
Файл целей: $TARGETS_FILE
Дата: $(date '+%d.%m.%Y %H:%M:%S')   Root: $IS_ROOT
$(printf '=%.0s' {1..70})"
echo -e "$HEADER\n"
echo "$HEADER" > "$REPORT"

while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  IP=$(echo "$line"    | awk '{print $1}')
  PROTO=$(echo "$line" | awk '{print $2}')
  PORTS=$(echo "$line" | awk '{print $3}')
  DESC=$(echo "$line"  | awk '{$1=$2=$3=""; print $0}' | xargs)
  [ -z "$DESC" ] && DESC="-"

  if [[ -z "$IP" || -z "$PROTO" || -z "$PORTS" ]]; then
    echo -e "${YELLOW}Пропускаю неверную строку: $line${NC}"
    continue
  fi

  check_host "$IP" "$PROTO" "$PORTS" "$DESC"
done < "$TARGETS_FILE"

SUMMARY="
$(printf '=%.0s' {1..70})
ИТОГО: проверено $TOTAL_HOSTS хостов | открыто $OPEN_COUNT | закрыто/фильтруется $CLOSED_COUNT | неизвестно $UNKNOWN_COUNT
$(printf '=%.0s' {1..70})"
echo -e "$SUMMARY"
echo "$SUMMARY" >> "$REPORT"

if [ ${#CLOSED_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}=== ТРЕБУЮТ ВНИМАНИЯ (для письма эксперту) ===${NC}"
  echo "" >> "$REPORT"
  echo "=== ТРЕБУЮТ ВНИМАНИЯ (для письма эксперту) ===" >> "$REPORT"
  for item in "${CLOSED_LIST[@]}"; do
    echo -e "  ${RED}✗${NC}  $item"
    echo "  $item" >> "$REPORT"
  done
fi

echo ""
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$REPORT" 2>/dev/null || true
echo "Отчёт сохранён: $REPORT"