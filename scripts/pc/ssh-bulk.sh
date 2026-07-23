#!/usr/bin/env bash
# ============================================================
#  ssh-bulk — выполнить команду на всех ПК из базы pc
#
#  Использование:
#    ssh-bulk "systemctl status sshd"
#    ssh-bulk --filter 192.168.111 "uname -r"
#    ssh-bulk --dry-run "apt list --upgradable 2>/dev/null | grep -c upgradable"
#
#  Опции:
#    --filter ПОДСТРОКА  — только ПК, IP которых содержит ПОДСТРОКУ
#    --dry-run           — показать список машин без выполнения
# ============================================================

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

check_dep gpg
check_dep ssh

FILTER=""
DRY_RUN=false

while [[ "$1" == --* ]]; do
  case "$1" in
    --filter)  FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo ""
      echo -e "  ${BOLD}ssh-bulk${RESET} [--filter ПОДСТРОКА] [--dry-run] \"команда\""
      echo ""
      echo -e "  Выполняет команду через sudo на всех ПК (тип 'pc') из базы паролей."
      echo -e "  Пропускает офлайн-машины."
      echo ""
      echo -e "  ${BOLD}--filter${RESET}   фильтр по подстроке IP (напр. 192.168.111)"
      echo -e "  ${BOLD}--dry-run${RESET}  показать список машин без выполнения"
      echo ""
      echo -e "  Примеры:"
      echo -e "    ssh-bulk \"systemctl status sshd\""
      echo -e "    ssh-bulk --filter 192.168.111 \"apt list --upgradable 2>/dev/null | grep -c upgradable\""
      echo -e "    ssh-bulk \"last -n 1 | head -1\""
      echo ""
      exit 0
      ;;
    *) echo -e "${RED}Неизвестный флаг:${RESET} $1"; exit 1 ;;
  esac
done

REMOTE_CMD="$1"

if [[ -z "$REMOTE_CMD" ]] && ! $DRY_RUN; then
  echo -e "${RED}Ошибка:${RESET} укажи команду для выполнения."
  echo -e "  Пример: ssh-bulk \"systemctl status sshd\""
  echo -e "  Помощь: ssh-bulk --help"
  exit 1
fi

echo -e "${CYAN}Расшифровываем базу pc...${RESET}"
TSV_DATA=$(gpg_decrypt) || exit 1

LOG_FILE="${HOME}/.config/pc/logs/ssh-bulk_$(date '+%Y-%m-%d_%H-%M').log"
mkdir -p "$(dirname "$LOG_FILE")"
{ echo "ssh-bulk — $(date)"; echo "Команда: ${REMOTE_CMD:-[dry-run]}"; echo "Фильтр:  ${FILTER:-нет}"; echo "======================================"; } > "$LOG_FILE"

total=0; success=0; failed=0; offline=0

echo ""
echo -e "${BOLD}${CYAN}  SSH Bulk${RESET}"
[[ -n "$REMOTE_CMD" ]] && echo -e "  Команда: ${BOLD}$REMOTE_CMD${RESET}"
[[ -n "$FILTER"     ]] && echo -e "  Фильтр:  ${BOLD}$FILTER${RESET}"
$DRY_RUN               && echo -e "  ${YELLOW}Режим: dry-run (выполнения не будет)${RESET}"
echo -e "  ──────────────────────────────────────────────────────"
printf "  %-25s %-18s %s\n" "Сотрудник" "IP" "Результат"
echo -e "  ──────────────────────────────────────────────────────"

while IFS=$'\t' read -r employee ip password type; do
  [[ "$employee" == "employee" ]] && continue
  [[ -z "$ip" || "$ip" == "-" ]] && continue
  [[ "$type" != "pc" ]] && continue
  [[ -n "$FILTER" && "$ip" != *"$FILTER"* ]] && continue

  (( total++ ))
  printf "  %-25s %-18s " "$employee" "$ip"

  if $DRY_RUN; then
    echo -e "${CYAN}● в списке${RESET}"
    continue
  fi

  if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
    echo -e "${YELLOW}● офлайн${RESET}"
    log OFFLINE "$employee ($ip)"
    (( offline++ ))
    continue
  fi

  output=$(ssh_run "$ip" "$password" <<< "$REMOTE_CMD" 2>&1)
  rc=$?

  if [[ $rc -eq 0 ]]; then
    if [[ -n "$output" ]]; then
      echo -e "${GREEN}● ок${RESET}"
      # Выводим вывод команды с отступом
      while IFS= read -r line; do
        echo -e "    ${CYAN}│${RESET} $line"
      done <<< "$output"
      log OK "$employee ($ip) → $output"
    else
      echo -e "${GREEN}● ок (нет вывода)${RESET}"
      log OK "$employee ($ip)"
    fi
    (( success++ ))
  else
    echo -e "${RED}● ошибка (rc=$rc)${RESET}"
    [[ -n "$output" ]] && echo -e "    ${RED}$output${RESET}"
    log FAIL "$employee ($ip) rc=$rc: $output"
    (( failed++ ))
  fi

done <<< "$(echo "$TSV_DATA" | grep -v '^\s*$')"

echo -e "  ──────────────────────────────────────────────────────"
echo ""
if $DRY_RUN; then
  echo -e "  ${BOLD}Машин в списке: $total${RESET}"
else
  echo -e "  ${BOLD}Итог:${RESET} всего $total | ${GREEN}ок: $success${RESET} | ${YELLOW}офлайн: $offline${RESET} | ${RED}ошибка: $failed${RESET}"
  echo -e "  Лог: ${BOLD}$LOG_FILE${RESET}"
fi
echo ""
