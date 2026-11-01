#!/bin/zsh
set -euo pipefail
DEMO_DIR="${0:A:h}"
if ! command -v uv >/dev/null 2>&1; then
    echo "uv gerekli: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi
exec uv run --project "$DEMO_DIR" --frozen python "$DEMO_DIR/demo.py" "$@"
