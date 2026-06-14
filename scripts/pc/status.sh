#!/usr/bin/env bash
# ============================================================
# status — обновляет обои экрана блокировки при SSH входе
# Определяет IP подключения → ищет имя в базе pc →
# генерирует картинку → меняет обои
# После выхода восстанавливает оригинальные обои
# ============================================================
VLAYSAVIN_HOME="/home/ATOMTES/vlaysavin"
PC_DB="${VLAYSAVIN_HOME}/.config/pc/computers.tsv.gpg"
WALLPAPER="${VLAYSAVIN_HOME}/Изображения/Wallpapers/fly-default-light.jpg"
BACKUP="${VLAYSAVIN_HOME}/Изображения/Wallpapers/fly-default-light.jpg.bak"
STATUS_IMG="/tmp/status_lock.jpg"
# ---------- определяем IP откуда пришли ----------
CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [[ -z "$CLIENT_IP" ]]; then
exec bash
exit 0
fi
# ---------- ищем имя в базе pc ----------
TSV_DATA=$(gpg --decrypt \
--pinentry-mode loopback \
"$PC_DB" 2>/dev/null)
NAME=$(echo "$TSV_DATA" | awk -F'\t' -v ip="$CLIENT_IP" '$2==ip {print $1; exit}')
if [[ -z "$NAME" ]]; then
NAME="$CLIENT_IP"
fi
# ---------- генерируем картинку со статусом ----------
DISPLAY=:0 python3 -c "
from PyQt5.QtWidgets import QApplication
from PyQt5.QtGui import QPixmap, QPainter, QColor, QFont
from PyQt5.QtCore import Qt
import sys
app = QApplication(sys.argv)
pixmap = QPixmap(1920, 1080)
# Загружаем оригинальные обои как фон
orig = QPixmap('${BACKUP}')
if not orig.isNull():
pixmap = orig.scaled(1920, 1080, Qt.KeepAspectRatioByExpanding)
else:
pixmap.fill(QColor(20, 40, 80))
painter = QPainter(pixmap)
# Полупрозрачная плашка
painter.fillRect(0, 420, 1920, 120, QColor(0, 0, 0, 160))
# Текст статуса
painter.setPen(QColor(255, 255, 255))
painter.setFont(QFont('Arial', 48, QFont.Bold))
painter.drawText(0, 420, 1920, 120, Qt.AlignCenter, 'На РМ: ${NAME}')
painter.end()
pixmap.save('${STATUS_IMG}', 'JPEG', 95)
" 2>/dev/null
# ---------- применяем обои ----------
if [[ -f "$STATUS_IMG" ]]; then
cp "$STATUS_IMG" "$WALLPAPER"
fi
echo "Статус установлен: На РМ — $NAME"
echo "Для сброса статуса введи: exit"
echo ""
# ---------- запускаем оболочку ----------
bash
# ---------- после выхода восстанавливаем оригинал ----------
if [[ -f "$BACKUP" ]]; then
cp "$BACKUP" "$WALLPAPER"
echo "Статус сброшен — обои восстановлены"
fi