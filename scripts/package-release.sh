#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Geçersiz sürüm: $VERSION" >&2
    exit 1
fi

VOICETYPE_UNIVERSAL_BUILD=1 ./scripts/build.sh
APP="$ROOT/VoiceTyping.app"
BINARY="$APP/Contents/MacOS/VoiceTyping"
codesign --verify --deep --strict "$APP"
lipo "$BINARY" -verify_arch arm64
lipo "$BINARY" -verify_arch x86_64
plutil -lint "$APP/Contents/Info.plist"

OUTPUT_DIR="$ROOT/dist"
FILENAME="VoiceType-${VERSION}-macOS.zip"
mkdir -p "$OUTPUT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$FILENAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$FILENAME" > "$FILENAME.sha256")
printf 'Paket hazır: %s\n' "$OUTPUT_DIR/$FILENAME"
printf 'Not: Bu paket Developer ID ile imzalanmış veya Apple tarafından noterlenmiş sayılmaz.\n'
