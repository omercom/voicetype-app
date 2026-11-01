#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
if ! command -v uv >/dev/null 2>&1; then
    echo "uv gerekli: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi
TTS_DIR="$HOME/.voice_typing/tts"
mkdir -p "$TTS_DIR"
chmod 700 "$TTS_DIR"
export UV_PROJECT_ENVIRONMENT="$TTS_DIR/.venv"
uv sync --project "$ROOT/experiments/antalia-mini-demo" --frozen --no-dev
"$TTS_DIR/.venv/bin/python" "$ROOT/Sources/VoiceTypingCore/Resources/ReadAloud/antalia_worker.py" --prepare
echo "✅ Antalia Mini hazır. VoiceType seçili metni yerelde seslendirebilir."
