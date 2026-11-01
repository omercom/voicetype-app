#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
if ! command -v uv >/dev/null 2>&1; then
    echo "uv gerekli. Önce https://docs.astral.sh/uv/ üzerinden kurun." >&2
    exit 1
fi
# Keep v0.1 intact until the new runtime and model have been verified.
STT_DIR="$HOME/.voice_typing/stt/seda-v0.2"
mkdir -p "$STT_DIR"
chmod 700 "$STT_DIR"
export UV_PROJECT_ENVIRONMENT="$STT_DIR/.venv"
export VOICETYPE_SEDA_HOME="$STT_DIR"
export HF_HUB_DISABLE_TELEMETRY=1
unset HF_HUB_OFFLINE
rm -f "$STT_DIR/ready.json"
uv sync --project "$ROOT/runtime/seda" --frozen --no-dev
"$STT_DIR/.venv/bin/python" "$ROOT/Sources/VoiceTypingCore/Resources/STT/seda_worker.py" --prepare
echo "✅ Seda-v0.2 hazır. Ayarlar → Yapay Zeka → Seda-v0.2 seçin; dil tr olmalı."
