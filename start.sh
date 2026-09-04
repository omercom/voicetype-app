#!/usr/bin/env bash
# start.sh - macOS Voice Typing Yerel Swift Uygulamasını Başlatıcı

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PID_FILE="$SCRIPT_DIR/.app.pid"
LOG_FILE="$SCRIPT_DIR/app.log"
BINARY="$SCRIPT_DIR/VoiceTyping"

# Halihazırda çalışan örnek varsa otomatik durdur ve yeniden başlat (Restart)
RESTARTED=0
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "🔄 Çalışan Voice Typing süreci tespit edildi (PID: $OLD_PID), kapatılıyor..."
        kill "$OLD_PID" 2>/dev/null
        sleep 0.5
        if ps -p "$OLD_PID" > /dev/null 2>&1; then
            kill -9 "$OLD_PID" 2>/dev/null
        fi
        RESTARTED=1
    fi
    rm -f "$PID_FILE"
fi

EXISTING_PIDS=$(pgrep -x "VoiceTyping" | tr '\n' ' ')
if [ -n "$EXISTING_PIDS" ]; then
    echo "🔄 Çalışan diğer Voice Typing süreçleri kapatılıyor: $EXISTING_PIDS"
    kill $EXISTING_PIDS 2>/dev/null
    sleep 0.5
    kill -9 $EXISTING_PIDS 2>/dev/null
    RESTARTED=1
fi

if [ $RESTARTED -eq 1 ]; then
    echo "✅ Önceki süreç başarıyla kapatıldı. Yeniden başlatılıyor..."
    sleep 0.5
fi

# Binary yoksa derle
if [ ! -f "$BINARY" ]; then
    echo "⚙️ Native Swift binary derleniyor..."
    swift build -c release && cp .build/release/VoiceTyping ./VoiceTyping
    if [ ! -f "$BINARY" ]; then
        echo "❌ Derleme başarısız oldu!"
        exit 1
    fi
fi

if [ "$1" == "--foreground" ] || [ "$1" == "-f" ]; then
    echo "🎙️ macOS Voice Typing (Native Swift) ön planda başlatılıyor (Çıkmak için Ctrl+C)..."
    exec "$BINARY"
else
    echo "🎙️ macOS Voice Typing (Native Swift) arka planda başlatılıyor..."
    nohup "$BINARY" >> "$LOG_FILE" 2>&1 &
    APP_PID=$!
    echo "$APP_PID" > "$PID_FILE"
    sleep 1

    if ps -p "$APP_PID" > /dev/null 2>&1; then
        echo "✅ Başarıyla başlatıldı! (PID: $APP_PID)"
        echo "📌 Menü çubuğundaki ses dalgası (waveform) simgesinden ayarları yönetebilirsiniz."
        echo "🎤 Kullanım: Herhangi bir metin kutusundayken Sağ Command tuşuna basılı tutun ve konuşun, bırakınca metin anında yapıştırılır."
        echo "⏹️ Durdurmak için: ./stop.sh"
        echo "📄 Logları izlemek için: tail -f app.log"
    else
        echo "❌ Uygulama başlatılamadı. Log dosyası:"
        cat "$LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi
fi
