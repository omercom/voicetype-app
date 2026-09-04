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

echo "✅ Build complete! Binary located at ./VoiceTyping ($(ls -lh ./VoiceTyping | awk '{print $5}'))"
echo "✅ App bundle created at ./$APP_BUNDLE"

