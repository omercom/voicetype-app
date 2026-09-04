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

# 4. Güvenlik imzası uygula (macOS TCC izinlerinin yeniden derlemede kaybolmaması için sabit kimlik kullanılır)
echo "🔏 4/5. Güvenlik imzası uygulanıyor (codesign)..."
SIGN_IDENTITY="VoiceTyping Local Certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep -s "$SIGN_IDENTITY" "$TARGET_APP" 2>/dev/null || codesign --force --deep --sign - "$TARGET_APP"
else
    codesign --force --deep --sign - "$TARGET_APP"
fi

# macOS LaunchServices önbelleğini yenile (LSUIElement / Dinamik Dock için)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" 2>/dev/null || true

# 4.5. Kullanıcı yapılandırmasını ve API anahtarlarını otomatik aktar / koru
echo "🔑 4.5/5. API anahtarları ve kullanıcı yapılandırması kontrol ediliyor..."
USER_CONFIG_DIR="$HOME/.voice_typing"
mkdir -p "$USER_CONFIG_DIR"

python3 - << 'PY_EOF'
import json
import os

user_cfg = os.path.expanduser("~/.voice_typing/config.json")
legacy_cfg = os.path.expanduser("~/.voice_typing_config.json")
project_cfg = os.path.abspath("config.json")
project_env = os.path.abspath(".env")

data = {}

if os.path.exists(user_cfg):
    try:
        with open(user_cfg, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass

if not data and os.path.exists(legacy_cfg):
    try:
        with open(legacy_cfg, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass

if os.path.exists(project_cfg):
    try:
        with open(project_cfg, "r", encoding="utf-8") as f:
            pdata = json.load(f)
            if not data:
                data = pdata
            else:
                for k in ["groq_api_key", "gemini_api_key", "provider", "gemini_model", "groq_model"]:
                    if not data.get(k) and pdata.get(k):
                        data[k] = pdata[k]
    except Exception:
        pass

if os.path.exists(project_env):
    try:
        with open(project_env, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("GROQ_API_KEY=") and not data.get("groq_api_key"):
                    data["groq_api_key"] = line.split("=", 1)[1].strip("\"' ")
                elif line.startswith("GEMINI_API_KEY=") and not data.get("gemini_api_key"):
                    data["gemini_api_key"] = line.split("=", 1)[1].strip("\"' ")
    except Exception:
        pass

if data:
    with open(user_cfg, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    with open(legacy_cfg, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    groq_ok = "✅" if data.get("groq_api_key") else "⚪"
    gemini_ok = "✅" if data.get("gemini_api_key") else "⚪"
    print(f"   ➔ API Anahtarları korundu ve eşitlendi (Groq: {groq_ok}, Gemini: {gemini_ok})")
PY_EOF

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
