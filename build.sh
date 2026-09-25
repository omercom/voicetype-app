#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building VoiceTyping native macOS binary with Swift Package Manager..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/VoiceTyping" ./VoiceTyping

# macOS .app Paketi Oluştur (TCC Mikrofon & Erişilebilirlik Desteği)
APP_BUNDLE="VoiceTyping.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp ./VoiceTyping "$APP_BUNDLE/Contents/MacOS/VoiceTyping"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Ses ve kaynak dosyalarını kopyala
BUNDLE_DIR="$BIN_DIR/VoiceTyping_VoiceTypingCore.bundle"
test -d "$BUNDLE_DIR"
rm -rf ./VoiceTyping_VoiceTypingCore.bundle
cp -R "$BUNDLE_DIR" ./VoiceTyping_VoiceTypingCore.bundle
cp -R "$BUNDLE_DIR" "$APP_BUNDLE/Contents/Resources/"
if [ -d "Sources/VoiceTypingCore/Resources" ]; then
    cp -R Sources/VoiceTypingCore/Resources/Sounds/*.wav "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    if [ -f "Sources/VoiceTypingCore/Resources/AppIcon.icns" ]; then
        cp "Sources/VoiceTypingCore/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    fi
fi
# Kullanıcı yapılandırması/API anahtarları .app paketine taşınmaz.
# Önceki bir build'den kalmış kaynak dosyasını da temizle.
rm -f "$APP_BUNDLE/Contents/Resources/config.json"

# Güvenlik İmzası (macOS TCC izinlerinin yeniden derlemede kaybolmaması için sabit kimlik kullanılır)
SIGN_IDENTITY="VoiceTyping Local Certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep -s "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

# Giriş Yöntemi paketi (pano kullanmadan metin yazar; ~/Library/Input Methods altına kurulur)
IME_BUNDLE="VoiceTypingIME.app"
rm -rf "$IME_BUNDLE"
mkdir -p "$IME_BUNDLE/Contents/MacOS" "$IME_BUNDLE/Contents/Resources"
cp "$BIN_DIR/VoiceTypingIME" "$IME_BUNDLE/Contents/MacOS/VoiceTypingIME"
cp Resources/IME/Info.plist "$IME_BUNDLE/Contents/Info.plist"
if [ -f "Sources/VoiceTypingCore/Resources/AppIcon.icns" ]; then
    cp "Sources/VoiceTypingCore/Resources/AppIcon.icns" "$IME_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep -s "$SIGN_IDENTITY" "$IME_BUNDLE"
else
    codesign --force --deep --sign - "$IME_BUNDLE"
fi
codesign --verify --deep --strict "$IME_BUNDLE"
plutil -lint "$IME_BUNDLE/Contents/Info.plist"

# macOS LaunchServices önbelleğini yenile (LSUIElement / Dinamik Dock için)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true

echo "✅ Build complete! Binary located at ./VoiceTyping ($(ls -lh ./VoiceTyping | awk '{print $5}'))"
echo "✅ App bundle created at ./$APP_BUNDLE"

