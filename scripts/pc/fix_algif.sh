#!/usr/bin/env bash
# ============================================================
#  fix_algif — массовое устранение уязвимости algif_aead
#  Читает базу pc, подключается по SSH к каждой машине,
#  блокирует загрузку модуля algif_aead
#  Использование: fix_algif
# ============================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

LOG_FILE="${HOME}/.config/pc/logs/fix_algif_$(date '+%Y-%m-%d_%H-%M').log"

REMOTE_CMD='
set -e
# Блокируем загрузку модуля
echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
# Выгружаем если сейчас загружен (ошибку игнорируем)
rmmod algif_aead 2>/dev/null || true
# Проверяем результат
if grep -q "algif_aead" /etc/modprobe.d/disable-algif.conf; then
  echo "OK"
else
  echo "FAIL"
  exit 1
fi
'

check_dep gpg
check_dep ssh

if ! command -v sshpass &>/dev/null; then
  echo -e "${YELLOW}⚠ sshpass не найден.${RESET}"
  echo -e "  Для автоматической передачи пароля: ${BOLD}sudo apt install sshpass${RESET}"
  echo -e "  Без sshpass скрипт попробует подключиться без пароля (SSH-ключ)."
  echo ""
  read -r -p "  Продолжить без sshpass? (y/n): " confirm
  [[ "$confirm" != "y" ]] && exit 0
fi

if [[ ! -f "$PC_DB_ENC" ]]; then
  echo -e "${RED}База pc не найдена:${RESET} $PC_DB_ENC"
  echo "Сначала настрой pc и заполни базу."
  exit 1
fi

echo -e "${CYAN}Расшифровываем базу pc...${RESET}"
TSV_DATA=$(gpg_decrypt) || exit 1

total=0; success=0; failed=0; skipped=0; offline=0

mkdir -p "$(dirname "$LOG_FILE")"
echo "fix_algif — $(date)" > "$LOG_FILE"
echo "======================================" >> "$LOG_FILE"

echo ""
echo -e "${BOLD}${CYAN}  Устранение уязвимости algif_aead${RESET}"
echo -e "  ──────────────────────────────────────────────────────"
printf "  %-25s %-18s %s\n" "Сотрудник" "IP" "Статус"
echo -e "  ──────────────────────────────────────────────────────"

while IFS=$'\t' read -r employee ip password type; do
  [[ "$employee" == "employee" ]] && continue
  [[ -z "$ip" || "$ip" == "-" ]] && continue
  [[ "$type" != "pc" ]] && continue

  (( total++ ))

  if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
    printf "  %-25s %-18s " "$employee" "$ip"
    echo -e "${YELLOW}● офлайн${RESET}"
    log OFFLINE "$employee ($ip)"
    (( offline++ ))
    continue
  fi

  printf "  %-25s %-18s " "$employee" "$ip"

  result=$(ssh_run "$ip" "$password" <<< "$REMOTE_CMD")

  if [[ "$result" == "OK" ]]; then
    echo -e "${GREEN}● готово${RESET}"
    log OK "$employee ($ip)"
    (( success++ ))
  elif [[ -z "$result" ]]; then
    echo -e "${RED}● нет доступа (SSH/пароль)${RESET}"
    log NO_ACCESS "$employee ($ip)"
    (( skipped++ ))
  else
    echo -e "${RED}● ошибка: $result${RESET}"
    log FAIL "$employee ($ip) — $result"
    (( failed++ ))
  fi

done <<< "$(echo "$TSV_DATA" | grep -v '^\s*$')"

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

if (( offline > 0 )); then
  echo -e "  ${YELLOW}⚠ $offline машин офлайн — запусти ${BOLD}algif_monitor${RESET}${YELLOW} для автообработки.${RESET}"
  echo ""
fi
