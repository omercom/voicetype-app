#!/usr/bin/env bash
# install.sh - macOS Voice Typing Kurulum ve Otomatik Başlatma Betiği
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="${1:-VoiceTyping}"
TARGET_APP="/Applications/${APP_NAME}.app"

echo "============================================================"
echo "📦 macOS Voice Typing Kurulumu Başlatılıyor..."
echo "📍 Hedef: $TARGET_APP"
echo "============================================================"

# 1. En son sürümü derle
echo "🔨 1/5. Native Swift binary ve .app paketi derleniyor..."
./build.sh

# 2. Çalışan eski süreçleri durdur
echo "🛑 2/5. Varsa önceki süreçler durduruluyor..."
./stop.sh 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x "VoiceTyping" 2>/dev/null || true
sleep 1

# 3. /Applications dizinine yükle
echo "📁 3/5. Uygulama /Applications klasörüne kopyalanıyor..."
rm -rf "$TARGET_APP"
cp -R VoiceTyping.app "$TARGET_APP"

# Eğer özel isim verildiyse Info.plist içindeki isimleri güncelle
if [ "$APP_NAME" != "VoiceTyping" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
fi

# 4. Ad-hoc codesigning yap (macOS TCC izinlerinin ve mikrofon onayının kalıcı olması için)
echo "🔏 4/5. Ad-hoc güvenlik imzası uygulanıyor (codesign)..."
codesign --force --deep --sign - "$TARGET_APP"

# 5. LaunchAgent oluştur (Mac açıldığında otomatik başlama)
echo "🚀 5/5. Başlangıçta otomatik çalışma (LaunchAgent) yapılandırılıyor..."
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.antigravity.VoiceTyping.plist"
mkdir -p "$LAUNCH_AGENT_DIR"

# Eski servis varsa kaldır
launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true

cat <<PLIST_EOF > "$LAUNCH_AGENT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.antigravity.VoiceTyping</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_APP/Contents/MacOS/VoiceTyping</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

# Servisi yükle (Mac açıldığında otomatik çalışması için)
launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null || true

# Servis başlatılmadıysa uygulamayı doğrudan aç
sleep 0.5
if ! pgrep -x "VoiceTyping" > /dev/null 2>&1; then
    open "$TARGET_APP"
fi

echo ""
echo "============================================================"
echo "🎉 Kurulum Başarıyla Tamamlandı!"
echo "📍 Konum: $TARGET_APP"
echo "🚀 Durum: Uygulama başlatıldı ve menü çubuğuna yerleşti."
echo "🔄 Otomatik Başlatma: Mac her açıldığında arka planda otomatik çalışacak."
echo "⌨️ Kullanım: Herhangi bir metin alanında Sağ Command (⌘) tuşuna basılı tutup konuşun!"
echo "============================================================"
