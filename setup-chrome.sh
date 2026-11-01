#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
PYTHON="$HOME/.voice_typing/tts/.venv/bin/python"
if [[ ! -x "$PYTHON" ]]; then
    echo "Önce ./setup-tts.sh ile yerel Antalia Mini motorunu kurun." >&2
    exit 1
fi
exec "$PYTHON" "$ROOT/browser-extension/install_host.py" "$@"
