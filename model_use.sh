#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/rag-sophia/app"
MID="${1:-}"
[[ -z "$MID" ]] && { echo "uso: $0 <model_id>"; exit 2; }
cd "$BASE"
source .venv/bin/activate
python -u model_registry.py use "$MID"
sudo systemctl restart sophia-api || true
