#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/rag-sophia/app"
cd "$BASE"
source .venv/bin/activate
export $(grep -v '^#' .env | xargs -d $'\n' -I{} echo {} | sed 's/\r$//')
python -u finetune_openai.py
