#!/bin/bash

LOG="logs/licenses_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

SUBNETS="192.168.111.0/24 192.168.121.0/24"
SSH_USER="vlaysavin"
SSH_PASS="q2Wc38qwjDC6gxE@#@"
SSH_OPTS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no"

ASTRA_COUNT=0
MYOFFICE_COUNT=0
TOTAL=0

echo "Сканирую сети..."
LIVE_HOSTS=$(nmap -Pn -p 22 --open --min-rate 500 $SUBNETS | grep "report for" | awk '{print $NF}')

for IP in $LIVE_HOSTS; do
    echo -n "$IP ..."

    RESULT=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$SSH_USER@$IP" '
            ASTRA=$(cat /etc/astra_version 2>/dev/null | head -1)
            MO=$(dpkg -l 2>/dev/null | grep -i "myoffice" | wc -l)
            echo "$ASTRA|$MO"
        ' 2>/dev/null)

    [ -z "$RESULT" ] && echo "недоступен" && continue

    TOTAL=$((TOTAL + 1))
    IFS='|' read -r ASTRA MO <<< "$RESULT"
    [ -n "$ASTRA" ] && ASTRA_COUNT=$((ASTRA_COUNT + 1))
    [[ "$MO" =~ ^[0-9]+$ ]] && [ "$MO" -gt 0 ] && MYOFFICE_COUNT=$((MYOFFICE_COUNT + 1))
    echo "OK"
done

echo ""
echo "Машин опрошено: $TOTAL"
echo "Лицензий Astra: $ASTRA_COUNT"
echo "Лицензий МойОфис: $MYOFFICE_COUNT"
