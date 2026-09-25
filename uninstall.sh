#!/usr/bin/env bash
# uninstall.sh - macOS Voice Typing Kaldırıcı
set -e

APP_NAME="${1:-VoiceTyping}"
TARGET_APP="/Applications/${APP_NAME}.app"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/com.antigravity.VoiceTyping.plist"

echo "🛑 Voice Typing durduruluyor..."
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x "VoiceTyping" 2>/dev/null || true

if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    echo "🔄 Başlangıçta otomatik başlatma servisi kaldırılıyor..."
    launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT_PLIST"
fi

if [ -d "$TARGET_APP" ]; then
    echo "🗑️ $TARGET_APP siliniyor..."
    rm -rf "$TARGET_APP"
    pkill -x VoiceTypingIME 2>/dev/null || true
    rm -rf "$HOME/Library/Input Methods/VoiceTypingIME.app"
    rm -f "$HOME/.voice_typing/ime_token"
fi

echo "✅ Uygulama ve otomatik başlangıç servisi başarıyla kaldırıldı."
