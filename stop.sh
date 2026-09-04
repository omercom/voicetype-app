#!/usr/bin/env bash
# stop.sh - macOS Voice Typing Uygulamasını Durdurucu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.app.pid"

STOPPED=0

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "🛑 Voice Typing durduruluyor (PID: $PID)..."
        kill "$PID" 2>/dev/null
        sleep 0.5
        if ps -p "$PID" > /dev/null 2>&1; then
            kill -9 "$PID" 2>/dev/null
        fi
        STOPPED=1
    fi
    rm -f "$PID_FILE"
fi

# Ekstra güvenlik: app.py ile çalışan başka örnekler varsa temizle
REMAINING=$(pgrep -f "python.*app\.py" | tr '\n' ' ')
if [ -n "$REMAINING" ]; then
    echo "🛑 Kalan app.py süreçleri kapatılıyor: $REMAINING"
    kill $REMAINING 2>/dev/null
    STOPPED=1
fi

if [ $STOPPED -eq 1 ]; then
    echo "✅ macOS Voice Typing başarıyla durduruldu."
else
    echo "ℹ️  Çalışan bir Voice Typing süreci bulunamadı."
fi
