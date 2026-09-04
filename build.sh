#!/usr/bin/env bash
set -e

echo "🔨 Building VoiceTyping native macOS binary with Swift Package Manager..."
swift build -c release
cp .build/release/VoiceTyping ./VoiceTyping

# macOS .app Paketi Oluştur (TCC Mikrofon & Erişilebilirlik Desteği)
APP_BUNDLE="VoiceTyping.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp ./VoiceTyping "$APP_BUNDLE/Contents/MacOS/VoiceTyping"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Ses ve kaynak dosyalarını kopyala
BUNDLE_DIR=$(find .build -name "VoiceTyping_VoiceTypingCore.bundle" | head -n 1)
if [ -n "$BUNDLE_DIR" ] && [ -d "$BUNDLE_DIR" ]; then
    cp -R "$BUNDLE_DIR" ./VoiceTyping_VoiceTypingCore.bundle
    cp -R "$BUNDLE_DIR" "$APP_BUNDLE/Contents/Resources/"
fi
if [ -d "Sources/VoiceTypingCore/Resources" ]; then
    cp -R Sources/VoiceTypingCore/Resources/Sounds/*.wav "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    if [ -f "Sources/VoiceTypingCore/Resources/AppIcon.icns" ]; then
        cp "Sources/VoiceTypingCore/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    fi
fi
if [ -f "config.json" ]; then
    cp "config.json" "$APP_BUNDLE/Contents/Resources/config.json" 2>/dev/null || true
fi

# Ad-hoc codesign (macOS TCC izinlerinin kalıcı olarak hatırlanması için)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "✅ Build complete! Binary located at ./VoiceTyping ($(ls -lh ./VoiceTyping | awk '{print $5}'))"
echo "✅ App bundle created at ./$APP_BUNDLE"

