#!/usr/bin/env bash
set -e

echo "🔨 Building VoiceTyping native macOS binary with Swift Package Manager..."
swift build -c release
cp .build/release/VoiceTyping ./VoiceTyping
echo "✅ Build complete! Binary located at ./VoiceTyping ($(ls -lh ./VoiceTyping | awk '{print $5}'))"
