sudo scp /etc/cups/ppd/PRINT-3.1.ppd administrator@192.168.111.111:/tmp/

sudo lpadmin -p PRINT-3.1 \
-E \
-v socket://192.168.111.200:9100 \
-P /tmp/PRINT-3.1.ppd \
-o media=A4
