#!/usr/bin/env bash
#===============================================================================
# install_sophia_llm.sh — Sophia RAG + Camada de Análise (TUDO em 1 script)
#===============================================================================
# - TUI completa com mouse (dialog) e fallback para whiptail.
# - Trata pacotes em HOLD (corrigir/ignorar/cancelar).
# - Remove containerd.io com segurança (sem quebrar docker/compose).
# - Chat pede/Salva OPENAI_API_KEY se faltar.
# - Sem modo offline e sem bloqueio de HTTP externo.
# - Adiciona Camada de Análise:
#     • SQL doc_analysis
#     • analyzers/: legal_extractors, argument_miner, contradiction_finder, timeline_builder
#     • Ferramentas: analyze_doc.py, analyze_batch.py, report_builder.py
#     • API: /analyze_doc, /analyze_batch, /analysis, /report
#     • TUI: 🧠 Análises (doc único, lote, relatório)
#===============================================================================
set -uo pipefail

#============================== CONSTANTES ===================================#
BASE_DIR="/opt/rag-sophia"
APP_DIR="${BASE_DIR}/app"
INITDB_DIR="${BASE_DIR}/initdb"
PGDATA_DIR="${BASE_DIR}/pgdata"
FINETUNE_DIR="${BASE_DIR}/finetune"
SESS_DIR="${BASE_DIR}/sessions"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
CONTAINER_NAME="rag_pg_sophia"
SERVICE_NAME="sophia-api"
API_PORT_DEFAULT="18888"

# Defaults
DEFAULT_DATA_DIR="${HOME}/ANEEL/sophia/aneel_biblioteca/results"
DEFAULT_DB_USER="rag"
DEFAULT_DB_NAME="rag"
DEFAULT_DB_PORT="25432"
DEFAULT_GEN_MODEL="gpt-5"
DEFAULT_REASONING_EFFORT="high"
DEFAULT_EMBED_MODEL="text-embedding-3-small"
DEFAULT_EXPANSION_MODEL="gpt-5"
DEFAULT_CHUNK_TOKENS="1100"
DEFAULT_CHUNK_OVERLAP="100"
DEFAULT_MAX_WORKERS="8"
DEFAULT_OCR_WORKERS="2"
DEFAULT_EMBED_BATCH_SIZE="256"
DEFAULT_EMBED_TOKEN_BUDGET="220000"
DEFAULT_LOG_LINES="5"
DEFAULT_LOG_EVERY="120"
DEFAULT_UFW_CIDR="0.0.0.0/0"
DEFAULT_DELTA_MODE="mtime_size"
DEFAULT_SKIP_SMOKE_TEST="true"
DEFAULT_PDF_SAMPLE_PAGES="1"
DEFAULT_TOPK="12"
DEFAULT_EXPANSIONS="4"
DEFAULT_RERANK_TOP="24"
DEFAULT_SELF_RAG="true"
DEFAULT_USE_QA_CACHE="true"
DEFAULT_QA_CACHE_TTL_DAYS="90"
DEFAULT_FEEDBACK_ALPHA="0.15"
DEFAULT_GLOSSARY_BOOST="0.2"
DEFAULT_NOTES_BOOST="0.35"
DEFAULT_ALLOW_FINETUNE="false"
DEFAULT_FINETUNE_BASE="gpt-4o-mini"
DEFAULT_API_PORT="${API_PORT_DEFAULT}"

#============================== VARIÁVEIS ====================================#
OPENAI_API_KEY=""
DATA_DIR="${DEFAULT_DATA_DIR}"
DB_USER="${DEFAULT_DB_USER}"
DB_NAME="${DEFAULT_DB_NAME}"
DB_PORT="${DEFAULT_DB_PORT}"
DB_PASS=""
GEN_MODEL="${DEFAULT_GEN_MODEL}"
REASONING_EFFORT="${DEFAULT_REASONING_EFFORT}"
EMBED_MODEL="${DEFAULT_EMBED_MODEL}"
EXPANSION_MODEL="${DEFAULT_EXPANSION_MODEL}"
CHUNK_TOKENS="${DEFAULT_CHUNK_TOKENS}"
CHUNK_OVERLAP="${DEFAULT_CHUNK_OVERLAP}"
MAX_WORKERS="${DEFAULT_MAX_WORKERS}"
OCR_WORKERS="${DEFAULT_OCR_WORKERS}"
EMBED_BATCH_SIZE="${DEFAULT_EMBED_BATCH_SIZE}"
EMBED_TOKEN_BUDGET="${DEFAULT_EMBED_TOKEN_BUDGET}"
LOG_LINES="${DEFAULT_LOG_LINES}"
LOG_EVERY="${DEFAULT_LOG_EVERY}"
UFW_CIDR="${DEFAULT_UFW_CIDR}"
OCR_ENABLED="true"
OCR_LANGS="por+eng"
OCR_DPI="200"
OCR_MAX_PAGES="8"
DELTA_MODE="${DEFAULT_DELTA_MODE}"
SKIP_SMOKE_TEST="${DEFAULT_SKIP_SMOKE_TEST}"
PDF_SAMPLE_PAGES="${DEFAULT_PDF_SAMPLE_PAGES}"
TOPK="${DEFAULT_TOPK}"
EXPANSIONS="${DEFAULT_EXPANSIONS}"
RERANK_TOP="${DEFAULT_RERANK_TOP}"
SELF_RAG="${DEFAULT_SELF_RAG}"
USE_QA_CACHE="${DEFAULT_USE_QA_CACHE}"
QA_CACHE_TTL_DAYS="${DEFAULT_QA_CACHE_TTL_DAYS}"
FEEDBACK_ALPHA="${DEFAULT_FEEDBACK_ALPHA}"
GLOSSARY_BOOST="${DEFAULT_GLOSSARY_BOOST}"
NOTES_BOOST="${DEFAULT_NOTES_BOOST}"
ALLOW_FINETUNE="${DEFAULT_ALLOW_FINETUNE}"
FINETUNE_BASE="${DEFAULT_FINETUNE_BASE}"
API_PORT="${DEFAULT_API_PORT}"

#============================== UI (dialog/whiptail) =========================#
need_root(){ [[ $EUID -eq 0 ]] || { echo "Execute como root: sudo $0"; exit 1; }; }
UI_BIN=""
UI_MODE="tui"
ui_detect(){
  if [[ ! -t 0 || ! -t 1 ]]; then
    UI_MODE="cli"
    return
  fi
  if command -v dialog >/dev/null 2>&1; then UI_BIN="dialog"; UI_MODE="dialog"; return; fi
  if command -v whiptail >/dev/null 2>&1; then UI_BIN="whiptail"; UI_MODE="whiptail"; return; fi
  printf '\n[Aviso] Preparando utilitários de interface (dialog/whiptail)...\n'
  apt-get update -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y dialog whiptail >/dev/null 2>&1 || true
  if command -v dialog >/dev/null 2>&1; then
    UI_BIN="dialog"; UI_MODE="dialog"; return
  fi
  if command -v whiptail >/dev/null 2>&1; then
    UI_BIN="whiptail"; UI_MODE="whiptail"; return
  fi
  UI_MODE="cli"
}
msgbox(){
  if [[ "$UI_MODE" == "dialog" ]]; then
    dialog --colors --mouse --scrollbar --msgbox "$1" 12 78
    return
  fi
  if [[ "$UI_MODE" == "whiptail" ]]; then
    whiptail --msgbox "$1" 12 78
    return
  fi
  printf '\n%s\n' "$1"
  read -r -p "[Enter] para continuar..." _dummy
}
inputbox(){
  if [[ "$UI_MODE" == "dialog" ]]; then
    dialog --mouse --inputbox "$2" 10 78 "$3" --title "$1" 2>/.tmp.inp || return 1
    cat /.tmp.inp
    return
  fi
  if [[ "$UI_MODE" == "whiptail" ]]; then
    whiptail --inputbox "$2" 10 78 "$3" --title "$1" 3>&1 1>&2 2>&3
    return
  fi
  local ans
  printf '\n[%s]\n%s\nValor padrão: %s\n> ' "$1" "$2" "$3"
  read -r ans
  if [[ -z "$ans" ]]; then
    printf '%s\n' "$3"
  else
    printf '%s\n' "$ans"
  fi
}
yesno(){
  if [[ "$UI_MODE" == "dialog" ]]; then
    dialog --mouse --yesno "$1" 10 78
    return
  fi
  if [[ "$UI_MODE" == "whiptail" ]]; then
    whiptail --yesno "$1" 10 78
    return
  fi
  local ans
  while true; do
    read -r -p "$1 [s/N]: " ans
    case "${ans,,}" in
      s|sim|y|yes) return 0 ;;
      n|nao|não|no|"" ) return 1 ;;
      *) echo "Responda com s ou n." ;;
    esac
  done
}
menu(){
  shift
  local text="$1"; shift
  if [[ "$UI_MODE" == "dialog" ]]; then
    dialog --mouse --menu "$text" 20 78 12 "$@" 2>/.tmp.sel || return 1
    cat /.tmp.sel
    return
  fi
  if [[ "$UI_MODE" == "whiptail" ]]; then
    whiptail --menu "$text" 20 78 12 "$@" 3>&1 1>&2 2>&3
    return
  fi
  local options=()
  while (( "$#" )); do
    local tag="$1"; shift
    local desc="$1"; shift
    options+=("$tag" "$desc")
  done
  echo "$text"
  for ((i=0; i<${#options[@]}; i+=2)); do
    printf '  [%s] %s\n' "${options[i]}" "${options[i+1]}"
  done
  local choice
  read -r -p "Escolha: " choice
  printf '%s\n' "$choice"
}
gauge(){
  if [[ "$UI_MODE" == "dialog" ]]; then
    dialog --mouse --gauge "$1" 18 90 0
    return
  fi
  if [[ "$UI_MODE" == "whiptail" ]]; then
    whiptail --gauge "$1" 18 90 0
    return
  fi
  local line
  while IFS= read -r line; do
    if [[ "$line" == \#* ]]; then
      echo "${line#\# }"
    fi
  done
}

#============================== HELPERS ======================================#
random_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; }
run_step(){
  local title="$1"; shift
  local log="/tmp/sophia_step.log"
  :> "$log"
  ( "$@" >>"$log" 2>&1 ) &
  local pid=$!
  if [[ "$UI_MODE" == "cli" ]]; then
    echo "== $title =="
    tail -n0 -f "$log" &
    local tail_pid=$!
    wait $pid
    local status=$?
    kill $tail_pid 2>/dev/null || true
    wait $tail_pid 2>/dev/null || true
    if (( status != 0 )); then
      local out="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -n 200)"
      msgbox "Falha em: $title\n\n$out"
      return 1
    fi
    echo "-- Finalizado: $title"
    return 0
  fi
  ( p=1; while kill -0 $pid 2>/dev/null; do echo $p; echo "# $title"; tail -n 5 "$log" 2>/dev/null; p=$(( (p+5) % 95 )); sleep 1; done; echo 100; echo "# Finalizado." ) | gauge "$title"
  wait $pid || { local out="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -n 200)"; msgbox "Falha em: $title\n\n$out"; return 1; }
  return 0
}

#============================= PRÉ-REQUISITOS/APT ============================#
apt_fix_and_install(){
  local holds; holds="$(apt-mark showhold 2>/dev/null || true)"
  if [[ -n "$holds" ]]; then
    local opt; opt="$(menu "Pacotes em HOLD" "Encontrados:\n$holds\nEscolha:" C "Corrigir (remover HOLD e ajustar)" I "Ignorar e continuar" X "Cancelar")" || opt="X"
    case "$opt" in C) apt-mark unhold $holds >/dev/null 2>&1 || true ;; I) : ;; X) return 1 ;; esac
  fi
  run_step "Instalando/ajustando pacotes (APT)..." bash -lc '
    set -u
    dpkg --configure -a || true
    apt -f install -y || true
    apt-get update -y
    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    if dpkg -l | awk "/^ii/ && /containerd\.io/ {exit 0} END{exit 1}"; then
      apt-get purge -y containerd.io || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y containerd || true
    fi
    FW_ON_HOLD=$(apt-mark showhold 2>/dev/null | grep -E "^firewalld$" || true)
    FW_INST=$(dpkg -l | awk "/^ii/ && /^firewalld/ {print \$2}" || true)
    EXTRA_FW="ufw"; [[ -n "$FW_ON_HOLD" || -n "$FW_INST" ]] && EXTRA_FW=""
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-plugin python3-venv $EXTRA_FW whiptail dialog jq tesseract-ocr tesseract-ocr-por tesseract-ocr-eng poppler-utils util-linux curl || true
    systemctl enable --now containerd 2>/dev/null || true
    systemctl enable --now docker 2>/dev/null || true
  '
  return 0
}

#============================= WIZARD CONFIG =================================#
cfg_wizard(){
  OPENAI_API_KEY="$(inputbox "🔐 OpenAI" "Informe sua OPENAI_API_KEY:" "$OPENAI_API_KEY")"
  DATA_DIR="$(inputbox "📁 Repositório" "Caminho (recursivo):" "$DEFAULT_DATA_DIR")"
  DB_USER="$(inputbox "🐘 Postgres" "Usuário:" "$DEFAULT_DB_USER")"
  DB_NAME="$(inputbox "🐘 Postgres" "Banco:" "$DEFAULT_DB_NAME")"
  DB_PORT="$(inputbox "🐘 Postgres" "Porta externa:" "$DEFAULT_DB_PORT")"
  local gen_default; gen_default="$(random_pass)"
  DB_PASS="$(inputbox "🐘 Postgres" "Senha (vazio=gerar):" "")"; [[ -z "$DB_PASS" ]] && DB_PASS="$gen_default"
  GEN_MODEL="$(inputbox "🤖 Geração" "Modelo gerativo:" "$DEFAULT_GEN_MODEL")"
  REASONING_EFFORT="$(inputbox "🧠 Esforço" "minimal|medium|high:" "$DEFAULT_REASONING_EFFORT")"
  EMBED_MODEL="$(inputbox "🧩 Embeddings" "Modelo:" "$DEFAULT_EMBED_MODEL")"
  EXPANSION_MODEL="$(inputbox "🔎 Expansão/Rerank" "Modelo:" "$DEFAULT_EXPANSION_MODEL")"
  CHUNK_TOKENS="$(inputbox "✂️ Chunk" "Tamanho (tokens):" "$DEFAULT_CHUNK_TOKENS")"
  CHUNK_OVERLAP="$(inputbox "✂️ Chunk" "Overlap (tokens):" "$DEFAULT_CHUNK_OVERLAP")"
  MAX_WORKERS="$(inputbox "⚡ FAST" "Workers fase 1:" "$DEFAULT_MAX_WORKERS")"
  OCR_WORKERS="$(inputbox "🖨️ OCR" "Workers OCR:" "$DEFAULT_OCR_WORKERS")"
  EMBED_BATCH_SIZE="$(inputbox "📦 Embeddings" "Lote (itens):" "$DEFAULT_EMBED_BATCH_SIZE")"
  EMBED_TOKEN_BUDGET="$(inputbox "📦 Embeddings" "Token budget:" "$DEFAULT_EMBED_TOKEN_BUDGET")"
  LOG_LINES="$(inputbox "🖥️ Log" "Linhas mostradas:" "$DEFAULT_LOG_LINES")"
  LOG_EVERY="$(inputbox "🖥️ Log" "Flush a cada N arquivos:" "$DEFAULT_LOG_EVERY")"
  UFW_CIDR="$(inputbox "🔓 Firewall" "Faixa IP Postgres:" "$DEFAULT_UFW_CIDR")"
  OCR_ENABLED="$(inputbox "🖨️ OCR" "Ativar OCR (true/false):" "true")"
  OCR_LANGS="$(inputbox "🖨️ OCR" "Idiomas (por+eng):" "por+eng")"
  OCR_DPI="$(inputbox "🖨️ OCR" "DPI:" "200")"
  OCR_MAX_PAGES="$(inputbox "🖨️ OCR" "Máx páginas (0=∞):" "8")"
  DELTA_MODE="$(inputbox "🧮 Delta" "mtime_size|sha:" "$DEFAULT_DELTA_MODE")"
  SKIP_SMOKE_TEST="$(inputbox "✅ Smoke-test OpenAI" "Pular? (true/false):" "$DEFAULT_SKIP_SMOKE_TEST")"
  PDF_SAMPLE_PAGES="$(inputbox "📄 Amostra PDF" "Páginas p/ detectar texto:" "$DEFAULT_PDF_SAMPLE_PAGES")"
  TOPK="$(inputbox "🔍 Recuperação" "Top-K:" "$DEFAULT_TOPK")"
  EXPANSIONS="$(inputbox "🔎 Expansão" "Variações:" "$DEFAULT_EXPANSIONS")"
  RERANK_TOP="$(inputbox "🏷️ Rerank" "Top-N:" "$DEFAULT_RERANK_TOP")"
  SELF_RAG="$(inputbox "🛡️ Self-RAG" "true/false:" "$DEFAULT_SELF_RAG")"
  USE_QA_CACHE="$(inputbox "⚡ Cache" "true/false:" "$DEFAULT_USE_QA_CACHE")"
  QA_CACHE_TTL_DAYS="$(inputbox "⚡ Cache" "TTL (dias):" "$DEFAULT_QA_CACHE_TTL_DAYS")"
  FEEDBACK_ALPHA="$(inputbox "📈 Feedback" "Peso α:" "$DEFAULT_FEEDBACK_ALPHA")"
  GLOSSARY_BOOST="$(inputbox "📚 Glossário" "Boost:" "$DEFAULT_GLOSSARY_BOOST")"
  NOTES_BOOST="$(inputbox "📝 Notas" "Boost:" "$DEFAULT_NOTES_BOOST")"
  ALLOW_FINETUNE="$(inputbox "🎯 Fine-tune" "Permitir via API? true/false:" "$DEFAULT_ALLOW_FINETUNE")"
  FINETUNE_BASE="$(inputbox "🎯 Fine-tune" "Modelo base:" "$DEFAULT_FINETUNE_BASE")"
  API_PORT="$(inputbox "🌐 API" "Porta HTTP da API:" "$DEFAULT_API_PORT")"
  [[ -z "$API_PORT" ]] && API_PORT="${API_PORT_DEFAULT}"
}

#=========================== ARQUIVOS DE SISTEMA ==============================#
write_files(){
  mkdir -p "${INITDB_DIR}" "${PGDATA_DIR}" "${APP_DIR}" "${SESS_DIR}" "${FINETUNE_DIR}" "${APP_DIR}/analyzers"
  chmod -R 755 "${BASE_DIR}"

  cat > "${BASE_DIR}/docker-compose.yml" <<YAML
services:
  postgres:
    image: pgvector/pgvector:pg16
    container_name: ${CONTAINER_NAME}
    environment:
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_DB: ${DB_NAME}
    ports: ["${DB_PORT}:5432"]
    volumes:
      - ./pgdata:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d
    restart: unless-stopped
YAML

  cat > "${INITDB_DIR}/001_schema.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE TABLE IF NOT EXISTS docs (
  id           BIGSERIAL PRIMARY KEY,
  path         TEXT NOT NULL,
  chunk_no     INT  NOT NULL,
  chunk_hash   TEXT NOT NULL,
  sha256       TEXT NOT NULL,
  mime         TEXT,
  size_bytes   BIGINT,
  mtime        TIMESTAMPTZ,
  title        TEXT,
  content      TEXT NOT NULL,
  meta         JSONB DEFAULT '{}'::jsonb,
  embedding    VECTOR(1536),
  tsv          TSVECTOR,
  UNIQUE(path, chunk_no)
);

CREATE TABLE IF NOT EXISTS emb_cache (
  chunk_hash   TEXT PRIMARY KEY,
  embedding    VECTOR(1536) NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS file_inventory (
  path        TEXT PRIMARY KEY,
  size_bytes  BIGINT NOT NULL,
  mtime       TIMESTAMPTZ NOT NULL,
  sha256      TEXT,
  last_seen   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS feedback (
  id          BIGSERIAL PRIMARY KEY,
  query_hash  TEXT NOT NULL,
  doc_id      BIGINT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
  signal      SMALLINT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS notes (
  id          BIGSERIAL PRIMARY KEY,
  author      TEXT,
  text        TEXT NOT NULL,
  tags        TEXT[],
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS glossary (
  term        TEXT PRIMARY KEY,
  definition  TEXT,
  weight      REAL DEFAULT 1.0,
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS qa_cache (
  qhash       TEXT PRIMARY KEY,
  question    TEXT NOT NULL,
  answer      TEXT NOT NULL,
  citations   JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION docs_tsv_update() RETURNS trigger AS $$
BEGIN
  NEW.tsv := to_tsvector('portuguese', unaccent(coalesce(NEW.content, '')));
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'docs_tsv_update_tr') THEN
    CREATE TRIGGER docs_tsv_update_tr
    BEFORE INSERT OR UPDATE OF content ON docs
    FOR EACH ROW EXECUTE FUNCTION docs_tsv_update();
  END IF;
END$$;

CREATE INDEX IF NOT EXISTS docs_tsv_idx        ON docs USING GIN (tsv);
CREATE INDEX IF NOT EXISTS docs_meta_gin       ON docs USING GIN (meta);
CREATE INDEX IF NOT EXISTS docs_chunk_hash_idx ON docs (chunk_hash);
SQL

  # --- Nova migração: doc_analysis ---
  cat > "${INITDB_DIR}/002_doc_analysis.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS doc_analysis (
  id BIGSERIAL PRIMARY KEY,
  doc_id BIGINT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  tipo TEXT, numero TEXT, data DATE, orgao TEXT,
  tema TEXT, processo_sei TEXT,
  summary TEXT,
  pros JSONB, cons JSONB,
  findings JSONB,
  citations JSONB NOT NULL,
  timeline JSONB,
  divergences JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(doc_id)
);
CREATE INDEX IF NOT EXISTS idx_da_path ON doc_analysis(path);
CREATE INDEX IF NOT EXISTS idx_da_tipo_data ON doc_analysis(tipo, data);
SQL

  cat > "${APP_DIR}/requirements.txt" <<'TXT'
openai>=1.40.0
tiktoken>=0.7.0
psycopg[binary]>=3.2.1
pypdf>=4.3.1
pdfminer.six>=20240706
beautifulsoup4>=4.12.3
pandas>=2.2.2
python-dotenv>=1.0.1
pytesseract>=0.3.10
pdf2image>=1.17.0
Pillow>=10.4.0
tqdm>=4.66.0
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.8.2
TXT

  cat > "${APP_DIR}/.env" <<ENV
OPENAI_API_KEY=${OPENAI_API_KEY}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:${DB_PORT}/${DB_NAME}
DATA_DIR=${DATA_DIR}

CHUNK_TOKENS=${CHUNK_TOKENS}
CHUNK_OVERLAP=${CHUNK_OVERLAP}
MAX_WORKERS=${MAX_WORKERS}
OCR_WORKERS=${OCR_WORKERS}
EMBED_BATCH_SIZE=${EMBED_BATCH_SIZE}
EMBED_TOKEN_BUDGET=${EMBED_TOKEN_BUDGET}

LOG_LINES=${LOG_LINES}
LOG_EVERY=${LOG_EVERY}

GEN_MODEL=${GEN_MODEL}
REASONING_EFFORT=${REASONING_EFFORT}
EMBED_MODEL=${EMBED_MODEL}
EXPANSION_MODEL=${EXPANSION_MODEL}

OCR_ENABLED=${OCR_ENABLED}
OCR_LANGS=${OCR_LANGS}
OCR_DPI=${OCR_DPI}
OCR_MAX_PAGES=${OCR_MAX_PAGES}

DELTA_MODE=${DELTA_MODE}
SKIP_SMOKE_TEST=${SKIP_SMOKE_TEST}
PDF_SAMPLE_PAGES=${PDF_SAMPLE_PAGES}

TOPK=${TOPK}
EXPANSIONS=${EXPANSIONS}
RERANK_TOP=${RERANK_TOP}
SELF_RAG=${SELF_RAG}
USE_QA_CACHE=${USE_QA_CACHE}
QA_CACHE_TTL_DAYS=${QA_CACHE_TTL_DAYS}
FEEDBACK_ALPHA=${FEEDBACK_ALPHA}
GLOSSARY_BOOST=${GLOSSARY_BOOST}
NOTES_BOOST=${NOTES_BOOST}

ALLOW_FINETUNE=${ALLOW_FINETUNE}
FINETUNE_BASE=${FINETUNE_BASE}
FINETUNE_DIR=${FINETUNE_DIR}
ENV

  # ---------------- Python: utils_text.py ----------------
  cat > "${APP_DIR}/utils_text.py" <<'PY'
import hashlib, os, logging, re
from bs4 import BeautifulSoup
from pypdf import PdfReader
import pandas as pd
import tiktoken
logging.getLogger("pypdf").setLevel(logging.ERROR)
logging.getLogger("pdfminer").setLevel(logging.ERROR)
_OCR_ENABLED  = (os.getenv("OCR_ENABLED","false").lower() == "true")
_OCR_LANGS    = os.getenv("OCR_LANGS","por+eng")
_OCR_DPI      = int(os.getenv("OCR_DPI","200"))
_OCR_MAX_PAGES= int(os.getenv("OCR_MAX_PAGES","8"))
_PDF_SAMPLE_PAGES = int(os.getenv("PDF_SAMPLE_PAGES","1"))
if _OCR_ENABLED:
    from pdf2image import convert_from_path
    import pytesseract
try:
    from pdfminer.high_level import extract_text as _pdfminer_extract
except Exception:
    _pdfminer_extract = None
ENC = tiktoken.get_encoding("cl100k_base")
_CTRL_RE = re.compile(r'[\x00-\x08\x0B\x0C\x0E-\x1F]')
def clean_text(s: str) -> str:
    if not s: return ""
    s = _CTRL_RE.sub(" ", s.replace("\x00", " "))
    return " ".join(s.split())
def clean_title(s: str) -> str:
    return clean_text(s)[:512] if s else ""
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024*1024), b""):
            h.update(chunk)
    return h.hexdigest()
def _pdf_text_pypdf(path: str, sample_only: bool=False, sample_pages: int=_PDF_SAMPLE_PAGES) -> str:
    try:
        try: reader = PdfReader(path, strict=False)
        except TypeError: reader = PdfReader(path)
        parts = []; pages = reader.pages
        n = min(len(pages), max(1, sample_pages))
        pages_iter = pages[:n] if sample_only else pages
        for page in pages_iter:
            txt = page.extract_text() or ""
            if txt: parts.append(txt)
        return clean_text("\n".join(parts))
    except Exception:
        return ""
def _pdf_text_pdfminer(path: str) -> str:
    if _pdfminer_extract is None: return ""
    try:
        txt = _pdfminer_extract(path) or ""
        return clean_text(txt)
    except Exception:
        return ""
def _pdf_text_ocr(path: str) -> str:
    if not _OCR_ENABLED: return ""
    try:
        images = convert_from_path(path, dpi=_OCR_DPI)
        parts = []
        for i, img in enumerate(images):
            if _OCR_MAX_PAGES and i >= _OCR_MAX_PAGES: break
            txt = pytesseract.image_to_string(img, lang=_OCR_LANGS)
            if txt: parts.append(txt)
        return clean_text("\n".join(parts))
    except Exception:
        return ""
def pdf_is_likely_textual(path: str, sample_pages: int=_PDF_SAMPLE_PAGES) -> bool:
    txt = _pdf_text_pypdf(path, sample_only=True, sample_pages=sample_pages)
    return len(txt) >= 30
def read_pdf_no_ocr(path: str) -> str:
    txt = _pdf_text_pypdf(path)
    if txt.strip(): return txt
    txt = _pdf_text_pdfminer(path)
    if txt.strip(): return txt
    return ""
def read_pdf_full(path: str) -> str:
    txt = read_pdf_no_ocr(path)
    if txt.strip(): return txt
    return _pdf_text_ocr(path)
def read_html(path: str) -> str:
    with open(path, "rb") as f: html = f.read()
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script","style","noscript"]): tag.decompose()
    return clean_text(soup.get_text(" "))
def read_xlsx(path: str) -> str:
    xls = pd.ExcelFile(path)
    texts = []
    for sheet in xls.sheet_names:
        df = xls.parse(sheet)
        txt = f"## Sheet: {sheet}\n" + df.fillna("").astype(str).to_csv(sep=" ", index=False)
        texts.append(clean_text(txt))
    return "\n\n".join(texts)
def extract_text_no_ocr(path: str) -> str:
    ext = os.path.splitext(path.lower())[1]
    try:
        if ext == ".pdf": return read_pdf_no_ocr(path)
        if ext in (".html",".htm"): return read_html(path)
        if ext in (".xlsx",".xls"): return read_xlsx(path)
        with open(path, "r", errors="ignore") as f: return clean_text(f.read())
    except Exception:
        return ""
    return ""
def extract_text_full(path: str) -> str:
    ext = os.path.splitext(path.lower())[1]
    try:
        if ext == ".pdf": return read_pdf_full(path)
        if ext in (".html",".htm"): return read_html(path)
        if ext in (".xlsx",".xls"): return read_xlsx(path)
        with open(path, "r", errors="ignore") as f: return clean_text(f.read())
    except Exception:
        return ""
    return ""
def chunk_by_tokens(text: str, chunk_tokens=1100, overlap=100):
    tokens = ENC.encode(text or "")
    if not tokens: return []
    out=[]; i=0; n=len(tokens)
    while i < n:
        j = min(i + chunk_tokens, n)
        chunk = ENC.decode(tokens[i:j]).strip()
        if chunk: out.append(clean_text(chunk))
        if j == n: break
        i = max(0, j - overlap)
    return out
PY

  # ---------------- Python: search_utils.py ----------------
  cat > "${APP_DIR}/search_utils.py" <<'PY'
import os, json, hashlib
from openai import OpenAI
import psycopg
from psycopg.rows import dict_row
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
DB_URL = os.getenv("DATABASE_URL")
GEN_MODEL = os.getenv("GEN_MODEL","gpt-5")
EXP_MODEL = os.getenv("EXPANSION_MODEL", GEN_MODEL)
REASONING_EFFORT = os.getenv("REASONING_EFFORT","high")
TOPK = int(os.getenv("TOPK","12"))
EXPANSIONS = int(os.getenv("EXPANSIONS","4"))
RERANK_TOP = int(os.getenv("RERANK_TOP","24"))
SELF_RAG = os.getenv("SELF_RAG","true").lower()=="true"
USE_QA_CACHE = os.getenv("USE_QA_CACHE","true").lower()=="true"
QA_CACHE_TTL_DAYS = int(os.getenv("QA_CACHE_TTL_DAYS","90"))
FEEDBACK_ALPHA = float(os.getenv("FEEDBACK_ALPHA","0.15"))
GLOSSARY_BOOST = float(os.getenv("GLOSSARY_BOOST","0.2"))
NOTES_BOOST = float(os.getenv("NOTES_BOOST","0.35"))
SQL_BASE = """
WITH q AS (
  SELECT websearch_to_tsquery('portuguese', %(q)s) AS tsq,
         %(qvec)s::vector(1536) AS qvec
),
lex AS (
  SELECT id, ts_rank_cd(d.tsv, q.tsq) AS lscore
  FROM docs d, q
  WHERE d.tsv @@ q.tsq
  ORDER BY lscore DESC
  LIMIT 300
),
vec AS (
  SELECT id, 1 - (d.embedding <=> q.qvec) AS vscore
  FROM docs d, q
  WHERE d.embedding IS NOT NULL
  ORDER BY d.embedding <=> q.qvec
  LIMIT 300
),
u AS (
  SELECT COALESCE(lex.id, vec.id) AS id,
         COALESCE(lex.lscore, 0) AS lscore,
         COALESCE(vec.vscore, 0) AS vscore
),
joined AS (
  SELECT d.id, d.path, d.chunk_no, d.title, d.meta, d.content,
         (0.6 * lscore + 0.4 * vscore) AS base_score
  FROM u JOIN docs d ON d.id = u.id
),
fb AS (
  SELECT doc_id, SUM(signal)::REAL AS fscore FROM feedback GROUP BY doc_id
)
SELECT j.*, COALESCE(fb.fscore,0) AS fscore
FROM joined j
LEFT JOIN fb ON fb.doc_id = j.id
ORDER BY base_score DESC
LIMIT %(n)s;
"""
def sha(text:str) -> str: return hashlib.sha256(text.encode("utf-8",errors="ignore")).hexdigest()
def embed_query(q:str, embed_model:str):
    return client.embeddings.create(model=embed_model, input=q).data[0].embedding
def expand_query(q:str) -> list[str]:
    if EXPANSIONS <= 0: return [q]
    prompt = f"Gere {EXPANSIONS} variações curtas e técnicas para a consulta abaixo, uma por linha.\n\nConsulta: {q}"
    r = client.chat.completions.create(model=EXP_MODEL, messages=[{"role":"user","content":prompt}], temperature=0.3)
    lines=[l.strip("-• ").strip() for l in r.choices[0].message.content.splitlines() if l.strip()]
    uniq=[]; seen=set()
    for s in [q]+lines:
        if s not in seen:
            uniq.append(s); seen.add(s)
        if len(uniq)>=EXPANSIONS+1: break
    return uniq
def rerank_pairs(question:str, items:list[dict]) -> list[dict]:
    if not items: return items
    chunks=items[:int(os.getenv("RERANK_TOP","24"))]
    trechos = "\n".join([f"[{i}] {c['content'][:800]}" for i,c in enumerate(chunks)])
    msgs=[{"role":"system","content":"Dê nota 0..10 para relevância de cada trecho vs pergunta. Responda JSON: [{idx,score}]"},
          {"role":"user","content":"Pergunta: "+question+"\n\nTrechos:\n"+trechos}]
    r=client.chat.completions.create(model=EXP_MODEL, messages=msgs, temperature=0)
    import json as _json
    try:
        scores=_json.loads(r.choices[0].message.content)
        for s in scores:
            idx=s.get("idx"); sc=float(s.get("score",0))
            if isinstance(idx,int) and 0<=idx<len(chunks): chunks[idx]["rerank"]=sc
    except Exception:
        for i,_ in enumerate(chunks): chunks[i]["rerank"]=0.0
    for i in range(len(chunks), len(items)): items[i]["rerank"]=0.0
    for it in items:
        it["final_score"]=it.get("base_score",0)+FEEDBACK_ALPHA*it.get("fscore",0)+(it.get("rerank",0)/10.0)
    items.sort(key=lambda x:x["final_score"], reverse=True)
    return items
def apply_glossary_boost(question:str, rows:list[dict]):
    if GLOSSARY_BOOST<=0: return rows
    terms=[]
    with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT term, weight FROM glossary"); terms=cur.fetchall()
    ql=question.lower()
    for r in rows:
        bonus=0.0; txt=(r.get("content") or "").lower()
        for t in terms:
            term=t["term"].lower(); w=float(t["weight"] or 1.0)
            if term in ql or term in txt: bonus += GLOSSARY_BOOST*w*0.1
        r["base_score"] += bonus
    return rows
def inject_notes(rows:list[dict]):
    if NOTES_BOOST<=0: return rows
    with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT id, text FROM notes ORDER BY created_at DESC LIMIT 50;"); ns=cur.fetchall()
    for n in ns:
        rows.append({"id": 10_000_000 + n["id"], "path": f"NOTE:{n['id']}", "chunk_no": 0, "title": "Nota",
                     "meta": {}, "content": n["text"], "base_score": NOTES_BOOST, "fscore": 0.0})
    return rows
def try_cache(question:str):
    if not USE_QA_CACHE: return None
    with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute("""SELECT answer, citations, created_at FROM qa_cache
                       WHERE qhash=%s AND created_at >= now() - interval '%s days'""",
                    (sha(question), os.getenv("QA_CACHE_TTL_DAYS","90")))
        return cur.fetchone()
def save_cache(question:str, answer:str, citations:list[dict]):
    if not USE_QA_CACHE: return
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("""INSERT INTO qa_cache(qhash,question,answer,citations,created_at)
                       VALUES(%s,%s,%s,%s,now())
                       ON CONFLICT (qhash) DO UPDATE SET
                         question=EXCLUDED.question, answer=EXCLUDED.answer,
                         citations=EXCLUDED.citations, created_at=now()""",
                    (sha(question), question, answer, psycopg.types.json.Json(citations))); conn.commit()
def self_rag_verify(draft:str, contexts:str) -> str:
    if os.getenv("SELF_RAG","true").lower()!="true": return draft
    prompt = f"""Revise a resposta abaixo, mantendo apenas afirmações suportadas pelo CONTEXTO.
Se algo não estiver claramente suportado, remova ou marque como incerto. Mantenha as citações [#n].
RESPOSTA:\n{draft}\n\nCONTEXTO:\n{contexts}"""
    r = client.chat.completions.create(model=GEN_MODEL,
        messages=[{"role":"system","content":"Você é um verificador factual rigoroso."},
                  {"role":"user","content":prompt}], temperature=0.0)
    return r.choices[0].message.content
def retrieve_hybrid(question:str, qvec, k:int=TOPK) -> list[dict]:
    with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SET hnsw.ef_search=100;")
        cur.execute(SQL_BASE, {"q":question, "qvec":qvec, "n": max(k*3, int(os.getenv('RERANK_TOP','24')))})
        return cur.fetchall()
PY

  # ---------------- Python: ingest.py ----------------
  cat > "${APP_DIR}/ingest.py" <<'PY'
from pathlib import Path
import os, hashlib, threading, queue, time
from datetime import datetime
from dotenv import load_dotenv
import psycopg
from psycopg.rows import dict_row
from openai import OpenAI
from concurrent.futures import ProcessPoolExecutor, as_completed
from collections import deque
from tqdm import tqdm
from utils_text import (extract_text_no_ocr, extract_text_full, chunk_by_tokens, sha256_file,
    pdf_is_likely_textual, clean_title)
load_dotenv(Path(__file__).with_name(".env"), override=True)
DATA_DIR = Path(os.getenv("DATA_DIR",".")).expanduser()
DB_URL = os.getenv("DATABASE_URL")
CHUNK_TOKENS = int(os.getenv("CHUNK_TOKENS","1100"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP","100"))
MAX_WORKERS = int(os.getenv("MAX_WORKERS","8"))
OCR_WORKERS = int(os.getenv("OCR_WORKERS","2"))
EMBED_MODEL = os.getenv("EMBED_MODEL","text-embedding-3-small")
EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE","256"))
EMBED_TOKEN_BUDGET = int(os.getenv("EMBED_TOKEN_BUDGET","220000"))
OCR_ENABLED = os.getenv("OCR_ENABLED","false").lower() == "true"
LOG_LINES = int(os.getenv("LOG_LINES","5"))
LOG_EVERY = int(os.getenv("LOG_EVERY","120"))
DELTA_MODE = os.getenv("DELTA_MODE","mtime_size")
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
ALLOWED_EXT = {".pdf",".html",".htm",".xlsx",".xls",".txt"}
def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS unaccent;")
        cur.execute("""
        CREATE TABLE IF NOT EXISTS docs (
          id BIGSERIAL PRIMARY KEY,
          path TEXT NOT NULL,
          chunk_no INT NOT NULL,
          chunk_hash TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          mime TEXT,
          size_bytes BIGINT,
          mtime TIMESTAMPTZ,
          title TEXT,
          content TEXT NOT NULL,
          meta JSONB DEFAULT '{}'::jsonb,
          embedding VECTOR(1536),
          tsv TSVECTOR,
          UNIQUE(path, chunk_no)
        );""")
        cur.execute("""CREATE TABLE IF NOT EXISTS emb_cache (chunk_hash TEXT PRIMARY KEY, embedding VECTOR(1536) NOT NULL, created_at TIMESTAMPTZ DEFAULT now());""")
        cur.execute("""CREATE TABLE IF NOT EXISTS file_inventory (path TEXT PRIMARY KEY, size_bytes BIGINT NOT NULL, mtime TIMESTAMPTZ NOT NULL, sha256 TEXT, last_seen TIMESTAMPTZ DEFAULT now());""")
        cur.execute("""
        CREATE OR REPLACE FUNCTION docs_tsv_update() RETURNS trigger AS $f$
        BEGIN NEW.tsv := to_tsvector('portuguese', unaccent(coalesce(NEW.content, ''))); RETURN NEW; END $f$ LANGUAGE plpgsql;""")
        cur.execute("""DO $$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='docs_tsv_update_tr') THEN
            CREATE TRIGGER docs_tsv_update_tr BEFORE INSERT OR UPDATE OF content ON docs
            FOR EACH ROW EXECUTE FUNCTION docs_tsv_update();
          END IF; END $$;""")
        cur.execute("CREATE INDEX IF NOT EXISTS docs_tsv_idx ON docs USING GIN (tsv);")
        cur.execute("CREATE INDEX IF NOT EXISTS docs_meta_gin ON docs USING GIN (meta);")
        cur.execute("CREATE INDEX IF NOT EXISTS docs_chunk_hash_idx ON docs (chunk_hash);")
    conn.commit()
def drop_hnsw_if_exists(conn):
    with conn.cursor() as cur: cur.execute("DROP INDEX IF EXISTS docs_embedding_hnsw;"); conn.commit()
def create_hnsw_concurrently(conn):
    old=conn.autocommit; conn.autocommit=True
    try:
        with conn.cursor() as cur:
            cur.execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS docs_embedding_hnsw ON docs USING hnsw (embedding vector_cosine_ops);")
    finally:
        conn.autocommit=old
def clean_text_safe(s:str)->str: return (s or "").replace("\x00"," ").strip()
def upsert_chunk(conn, path, chunk_no, chunk_hash, sha256, size_bytes, mtime, title, content, meta):
    title = clean_text_safe(title); content = clean_text_safe(content)
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute("""
          INSERT INTO docs(path, chunk_no, chunk_hash, sha256, size_bytes, mtime, title, content, meta)
          VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)
          ON CONFLICT (path, chunk_no) DO UPDATE SET
            chunk_hash=EXCLUDED.chunk_hash, sha256=EXCLUDED.sha256, size_bytes=EXCLUDED.size_bytes,
            mtime=EXCLUDED.mtime, title=EXCLUDED.title, content=EXCLUDED.content, meta=EXCLUDED.meta
          RETURNING id;""",(path, chunk_no, chunk_hash, sha256, size_bytes, mtime, title, content, psycopg.types.json.Json(meta)))
        return cur.fetchone()["id"]
class EmbeddingWorker(threading.Thread):
    def __init__(self, dsn, batch_size, model, token_budget):
        super().__init__(daemon=True); self.dsn=dsn; self.batch_size=batch_size; self.model=model; self.token_budget=token_budget
        self.q=queue.Queue(maxsize=max(64, batch_size*8)); self.stop=False; self.pending=[]; self.pending_tokens=0; self.last_flush=0.0; self.max_wait=10.0
        self.client=OpenAI(api_key=os.getenv("OPENAI_API_KEY")); import tiktoken as tk; self.enc=tk.get_encoding("cl100k_base")
    def run(self):
        with psycopg.connect(self.dsn) as conn:
            with conn.cursor() as cur: cur.execute("SET synchronous_commit=off;")
            while not self.stop or self.pending:
                try:
                    item=self.q.get(timeout=0.3)
                    if item is None: self.stop=True; continue
                    self._queue(item)
                except queue.Empty: pass
                if self.pending and (time.time()-self.last_flush)>=self.max_wait: self._flush(conn)
            if self.pending: self._flush(conn)
    def _queue(self, item):
        doc_id, chash, text = item
        tc=len(self.enc.encode(text or ""))
        if (self.pending_tokens+tc)>self.token_budget or len(self.pending)>=self.batch_size:
            self._flush(psycopg.connect(self.dsn)); self.pending=[]; self.pending_tokens=0
        self.pending.append((doc_id, chash, text)); self.pending_tokens+=tc
    def _flush(self, conn):
        if not self.pending: return
        hashes=[h for _,h,_ in self.pending]
        texts=[clean_text_safe(t) for *_,t in self.pending]
        out=[]; start=0
        while start<len(texts):
            sub=texts[start:start+self.batch_size]
            out.extend(self.client.embeddings.create(model=self.model, input=sub).data); start+=self.batch_size
        with conn.cursor() as cur:
            cur.executemany("INSERT INTO emb_cache(chunk_hash, embedding) VALUES(%s,%s) ON CONFLICT (chunk_hash) DO NOTHING",
                            list({h:v.embedding for h,v in zip(hashes,out)}.items()))
            cur.executemany("UPDATE docs d SET embedding=c.embedding FROM emb_cache c WHERE d.id=%s AND c.chunk_hash=%s",
                            [(doc_id, chash) for doc_id, chash, _ in self.pending])
        conn.commit(); self.pending.clear(); self.pending_tokens=0; self.last_flush=time.time()
    def submit(self, doc_id, chash, text): self.q.put((doc_id, chash, text))
    def finish(self): self.q.put(None); self.join()
def upsert_inventory(conn, path:str, size_bytes:int, mtime, sha:str):
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO file_inventory(path,size_bytes,mtime,sha256,last_seen)
                       VALUES(%s,%s,%s,%s,now())
                       ON CONFLICT(path) DO UPDATE SET size_bytes=EXCLUDED.size_bytes, mtime=EXCLUDED.mtime, sha256=EXCLUDED.sha256, last_seen=now();""",
                    (path,size_bytes,mtime,sha)); conn.commit()
def iter_all_files(root: Path):
    for p,_,files in os.walk(root):
        for f in files:
            ext=os.path.splitext(f)[1].lower()
            if ext in {".pdf",".html",".htm",".xlsx",".xls",".txt"}:
                yield Path(p)/f
def process_no_ocr(path: str, chunk_tokens: int, overlap: int):
    p=Path(path); st=p.stat(); title=p.stem
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda: f.read(1<<20), b""):
            h.update(b)
    file_sha=h.hexdigest()
    text=extract_text_no_ocr(str(p))
    chunks=chunk_by_tokens(text, chunk_tokens, overlap) if text.strip() else []
    return dict(path=str(p), chunks=chunks, sha=file_sha, size_bytes=st.st_size,
                mtime=datetime.fromtimestamp(st.st_mtime), title=title, mode="FAST")
def process_with_ocr(path: str, chunk_tokens: int, overlap: int):
    p=Path(path); st=p.stat(); title=p.stem
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda: f.read(1<<20), b""):
            h.update(b)
    file_sha=h.hexdigest()
    text=extract_text_full(str(p))
    chunks=chunk_by_tokens(text, chunk_tokens, overlap) if text.strip() else []
    return dict(path=str(p), chunks=chunks, sha=file_sha, size_bytes=st.st_size,
                mtime=datetime.fromtimestamp(st.st_mtime), title=title, mode="OCR")
def ingest_group(conn, paths, use_ocr=False, workers=8, batch_size=256, desc=""):
    process_fn=process_with_ocr if use_ocr else process_no_ocr
    with conn.cursor() as cur: cur.execute("SET synchronous_commit=off;")
    embw=EmbeddingWorker(os.getenv("DATABASE_URL"), batch_size, os.getenv("EMBED_MODEL","text-embedding-3-small"),
                         int(os.getenv("EMBED_TOKEN_BUDGET","220000"))); embw.start()
    log_buf=deque(maxlen=1000); processed=0
    with ProcessPoolExecutor(max_workers=workers) as ex:
        futures=[ex.submit(process_fn, str(p), int(os.getenv("CHUNK_TOKENS","1100")), int(os.getenv("CHUNK_OVERLAP","100"))) for p in paths]
        with tqdm(total=len(futures), unit="arq", desc=desc, ascii=True, mininterval=0.2, dynamic_ncols=True) as bar:
            for fut in as_completed(futures):
                info=fut.result(); processed+=1
                log_buf.append(f"[{info['mode']}] {Path(info['path']).name}  chunks={len(info['chunks'])}")
                for idx, chunk in enumerate(info["chunks"]):
                    chash=hashlib.sha256((chunk or "").encode("utf-8",errors="ignore")).hexdigest()
                    doc_id=upsert_chunk(conn, info["path"], idx, chash, info["sha"], info["size_bytes"], info["mtime"], info["title"], chunk,
                                        {"dir": str(Path(info["path"]).parent), "ext": Path(info["path"]).suffix.lower()})
                    with conn.cursor() as cur:
                        cur.execute("SELECT embedding IS NULL FROM docs WHERE id=%s",(doc_id,))
                        if cur.fetchone()[0]: embw.submit(doc_id, chash, chunk)
                upsert_inventory(conn, info["path"], info["size_bytes"], info["mtime"], info["sha"])
                if processed % int(os.getenv("LOG_EVERY","120")) == 0:
                    tail=list(log_buf)[-int(os.getenv("LOG_LINES","5")):]
                    if tail: from tqdm import tqdm as _t; _t.write("\n".join(tail))
                bar.update(1)
    embw.finish()
def main():
    DATA = DATA_DIR
    all_files=[p for p in iter_all_files(DATA)]
    all_files.sort(key=lambda p: p.stat().st_size if p.exists() else 0)
    with psycopg.connect(DB_URL) as conn:
        ensure_schema(conn)
        inv={}
        with conn.cursor() as cur:
            cur.execute("SELECT path,size_bytes,mtime,sha256 FROM file_inventory WHERE path LIKE %s", (str(DATA_DIR)+"%",))
            for path,size_bytes,mtime,sha in cur: inv[path]=(int(size_bytes), mtime, sha)
        added, maybe_mod, unchanged = [], [], []
        for p in all_files:
            st=p.stat(); size=st.st_size; mtime=datetime.fromtimestamp(st.st_mtime); rec=inv.get(str(p))
            if not rec: added.append(p)
            else:
                s0,m0,_=rec
                if size==s0 and mtime==m0: unchanged.append(p)
                else: maybe_mod.append(p)
        if os.getenv("DELTA_MODE","mtime_size")=="sha":
            changed=[]; from tqdm import tqdm as tq
            for p in tq(maybe_mod, desc="Verificando SHA (delta)", unit="arq", ascii=True):
                if sha256_file(str(p)) != inv.get(str(p),(None,None,None))[2]: changed.append(p)
        else:
            changed=maybe_mod
        targets=added+changed
        from tqdm import tqdm as _t; _t.write(f"[DELTA] Novos: {len(added)} | Alterados: {len(changed)} | Inalterados: {len(unchanged)}")
        drop_hnsw_if_exists(conn)
        fast_group, ocr_group = [], []
        for p in targets:
            if p.suffix.lower()==".pdf":
                (fast_group if pdf_is_likely_textual(str(p)) else ocr_group).append(p)
            else:
                fast_group.append(p)
        if fast_group:
            ingest_group(conn, fast_group, use_ocr=False, workers=int(os.getenv("MAX_WORKERS","8")),
                         batch_size=int(os.getenv("EMBED_BATCH_SIZE","256")), desc=f"Fase 1 (texto nativo) [{len(fast_group)}]")
        if os.getenv("OCR_ENABLED","false").lower()=="true" and ocr_group:
            ingest_group(conn, ocr_group, use_ocr=True, workers=int(os.getenv("OCR_WORKERS","2")),
                         batch_size=int(os.getenv("EMBED_BATCH_SIZE","256")), desc=f"Fase 2 (OCR) [{len(ocr_group)}]")
        create_hnsw_concurrently(conn)
    print("Ingestão concluída.")
if __name__=="__main__": main()
PY

  # ---------------- Python: analyzers ----------------------------------------
  cat > "${APP_DIR}/analyzers/legal_extractors.py" <<'PY'
import re, datetime
TIPO_RE = re.compile(r'\b(Despacho|Resolu[çc][aã]o(?: Normativa)?|Nota T[eé]cnica|Portaria|Relat[óo]rio)\b', re.I)
NUM_RE  = re.compile(r'(\d{1,5})\/(20\d{2})')
ORG_RE  = re.compile(r'\b(ANEEL|MME|ONS|SRG|SGT|SCG|SFF)\b', re.I)
DATE_RE = re.compile(r'\b(20\d{2})[-/\.](\d{1,2})[-/\.](\d{1,2})\b')
def norm_date(txt):
    m = DATE_RE.search(txt or "")
    if not m: return None
    y,mo,da = map(int, m.groups())
    try: return str(datetime.date(y,mo,da))
    except: return None
def extract_meta(text, fallback=None):
    t = (text or "")[:8000]
    tipo=None
    m=TIPO_RE.search(t)
    if m:
        tipo=m.group(1).title()
        if "Normativa" in m.group(0): tipo="Resolução Normativa"
    numero=None
    m=NUM_RE.search(t)
    if m: numero=f"{m.group(1)}/{m.group(2)}"
    orgao=None
    m=ORG_RE.search(t)
    if m: orgao=m.group(1).upper()
    data=norm_date(t)
    fb=fallback or {}
    return {"tipo":tipo or fb.get("tipo"), "numero":numero or fb.get("numero"), "orgao":orgao or fb.get("orgao"), "data":data or fb.get("data")}
PY

  cat > "${APP_DIR}/analyzers/argument_miner.py" <<'PY'
import json, os
from typing import List, Dict, Any
from openai import OpenAI
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
SYSTEM=("Você é analista jurídico-regulatório. Responda SÓ com base no CONTEXTO. "
        "Cada ponto deve conter support=[{n,path,chunk}]. Se faltar base, escreva 'falta base'.")
def _strict(prompt:str, contexts:List[Dict[str,Any]], model:str):
    parts=[]
    for i,c in enumerate(contexts,1):
        quote=(c.get("content","") or "")[:1200].replace("\x00"," ")
        parts.append(f"[#{i}] {c.get('path','')} (chunk {c.get('chunk',0)}): {quote}")
    ctx="\n".join(parts)
    msgs=[{"role":"system","content":SYSTEM},
          {"role":"user","content": f"CONTEXTO:\n{ctx}\n\nINSTRUÇÃO:\n{prompt}\nResponda em JSON válido."}]
    r=client.chat.completions.create(model=model, temperature=0.1, messages=msgs)
    return r.choices[0].message.content
def pros_cons(contexts, model):
    prompt=("Liste prós e contras com justificativas. "
            "Formato JSON: {\"pros\":[{\"claim\":\"...\",\"why\":\"...\",\"support\":[{\"n\":1,\"path\":\"...\",\"chunk\":7}]}],"
            "\"cons\":[{\"claim\":\"...\",\"why\":\"...\",\"support\":[{\"n\":2,\"path\":\"...\",\"chunk\":3}]}]}")
    out=_strict(prompt, contexts, model)
    try:
        data=json.loads(out); assert "pros" in data and "cons" in data; return data
    except Exception:
        return {"pros": [], "cons": [], "raw": out}
def summary_findings(contexts, model):
    prompt=("Faça um resumo crítico em 5-10 pontos e extraia achados relevantes. "
            "JSON: {\"summary\":\"...\",\"findings\":[{\"what\":\"...\",\"so_what\":\"...\",\"support\":[...]}]}")
    out=_strict(prompt, contexts, model)
    try: return json.loads(out)
    except Exception: return {"summary": "", "findings": [], "raw": out}
PY

  cat > "${APP_DIR}/analyzers/contradiction_finder.py" <<'PY'
import json, os
from typing import List, Dict, Any
from openai import OpenAI
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
SYSTEM=("Você identifica convergências e divergências objetivas ENTRE os trechos no CONTEXTO. "
        "Sempre cite support=[{n,path,chunk}]. Responda em JSON válido.")
def detect(contexts:List[Dict[str,Any]], model:str):
    if len(contexts)<2: return {"divergences": [], "convergences": []}
    parts=[]
    for i,c in enumerate(contexts,1):
        quote=(c.get("content","") or "")[:900].replace("\x00"," ")
        parts.append(f"[#{i}] {c.get('path','')} (chunk {c.get('chunk',0)}): {quote}")
    ctx="\n".join(parts)
    prompt=("Liste divergências e convergências relevantes entre os trechos. "
            "JSON: {\"divergences\":[{\"topic\":\"...\",\"views\":[\"...\"],\"support\":[...] }],"
            "\"convergences\":[{\"topic\":\"...\",\"consensus\":\"...\",\"support\":[...]}]}")
    r=client.chat.completions.create(model=model, temperature=0.1,
        messages=[{"role":"system","content":SYSTEM},{"role":"user","content":f"{ctx}\n\n{prompt}"}])
    try: return json.loads(r.choices[0].message.content)
    except Exception: return {"divergences": [], "convergences": [], "raw": r.choices[0].message.content}
PY

  cat > "${APP_DIR}/analyzers/timeline_builder.py" <<'PY'
import json, re, os
from typing import List, Dict, Any
from openai import OpenAI
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
DATE_RE=re.compile(r'\b(20\d{2})[-/\.](\d{1,2})[-/\.](\d{1,2})\b')
def detect_dates(text:str)->list:
    out=[]
    for m in DATE_RE.finditer(text or ""):
        y,mo,da=m.groups()
        try:
            y=int(y); mo=int(mo); da=int(da)
            out.append(f"{y:04d}-{mo:02d}-{da:02d}")
        except: pass
    return list(dict.fromkeys(out))[:50]
def build(contexts:List[Dict[str,Any]], model:str):
    if not contexts: return {"timeline":[]}
    snippets=[]
    for i,c in enumerate(contexts,1):
        txt=(c.get("content","") or "")[:1200]
        dts=detect_dates(txt)
        if dts: snippets.append(f"[#{i}] {c.get('path','')} (chunk {c.get('chunk',0)}): {txt}")
    if not snippets: return {"timeline":[]}
    prompt=("A partir dos trechos, componha uma linha do tempo (eventos concisos). "
            "JSON: {\"timeline\":[{\"date\":\"YYYY-MM-DD\",\"event\":\"...\",\"support\":[{\"n\":1,\"path\":\"...\",\"chunk\":0}]}]}")
    r=client.chat.completions.create(model=model, temperature=0.1,
        messages=[{"role":"system","content":"Seja factual e conciso."},{"role":"user","content":"\n".join(snippets)+"\n\n"+prompt}])
    try: return json.loads(r.choices[0].message.content)
    except Exception: return {"timeline": [], "raw": r.choices[0].message.content}
PY

  # ---------------- Python: search_answer.py ---------------------------------
  cat > "${APP_DIR}/search_answer.py" <<'PY'
from pathlib import Path
import os
from dotenv import load_dotenv
from openai import OpenAI
from search_utils import (embed_query, expand_query, retrieve_hybrid, rerank_pairs,
    apply_glossary_boost, inject_notes, try_cache, save_cache, self_rag_verify)
load_dotenv(Path(__file__).with_name(".env"), override=True)
GEN_MODEL = os.getenv("GEN_MODEL","gpt-5")
REASONING_EFFORT = os.getenv("REASONING_EFFORT","high")
EMBED_MODEL = os.getenv("EMBED_MODEL","text-embedding-3-small")
TOPK = int(os.getenv("TOPK","12"))
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
PROMPT = """
Você é um analista jurídico-regulatório. Responda usando apenas o contexto abaixo.
- Faça um resumo crítico.
- Liste favoráveis e contrários com justificativas.
- Compare documentos quando houver divergências/convergências.
- Cite fontes como [#n] + caminho.
- Se faltar base, diga o que falta.

Pergunta: "{question}"

Contexto:
{contexts}
"""
def answer(question, k=TOPK, max_ctx_chars=20000):
    row=try_cache(question)
    if row: print(row["answer"]); return
    variants=expand_query(question)
    all_rows=[]
    for v in variants:
        qvec=embed_query(v, os.getenv("EMBED_MODEL","text-embedding-3-small"))
        rows=retrieve_hybrid(v, qvec, k=k); all_rows.extend(rows)
    by_id={r["id"]:r for r in all_rows}; rows=list(by_id.values())
    rows=apply_glossary_boost(question, rows); rows=inject_notes(rows); rows=rerank_pairs(question, rows)
    blocks=[]; total=0; cites=[]
    for i,r in enumerate(rows[:k],1):
        header=f"[#{i}] {r['path']} (chunk {r['chunk_no']})"
        body=(r["content"] or "").replace("\n"," ").strip()
        piece=f"{header}\n{body}\n"
        if total+len(piece)>max_ctx_chars: break
        blocks.append(piece); total+=len(piece)
        cites.append({"n":i,"path":r["path"],"chunk":r["chunk_no"]})
    contexts="\n---\n".join(blocks)
    user_prompt=PROMPT.format(question=question, contexts=contexts)
    resp=client.chat.completions.create(model=GEN_MODEL,
        messages=[{"role":"system","content":"Responda tecnicamente, sem inventar fatos, e cite fontes."},
                  {"role":"user","content":user_prompt}], temperature=0.2,
        reasoning={"effort": REASONING_EFFORT})
    draft=resp.choices[0].message.content
    final=self_rag_verify(draft, contexts)
    print(final); save_cache(question, final, cites)
if __name__=="__main__":
    import sys
    q=" ".join(sys.argv[1:]) or "Quais entendimentos favoráveis e contrários sobre [tema]?"
    answer(q)
PY

  # ---------------- Python: search_chat.py -----------------------------------
  cat > "${APP_DIR}/search_chat.py" <<'PY'
from pathlib import Path
import os, json
from dotenv import load_dotenv
from openai import OpenAI
from search_utils import (retrieve_hybrid, apply_glossary_boost, inject_notes,
    rerank_pairs, self_rag_verify)
load_dotenv(Path(__file__).with_name(".env"), override=True)
GEN_MODEL = os.getenv("GEN_MODEL","gpt-5")
REASONING_EFFORT = os.getenv("REASONING_EFFORT","high")
EMBED_MODEL = os.getenv("EMBED_MODEL","text-embedding-3-small")
TOPK = int(os.getenv("TOPK","12"))
SESS_DIR = Path("/opt/rag-sophia/sessions"); SESS_DIR.mkdir(parents=True, exist_ok=True)
SYSTEM = "Você é um assistente analítico. Baseie-se no contexto recuperado e no histórico. Cite fontes como [#n] + caminho."
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
def chat_respond(session_name:str, user_text:str):
    qvec=client.embeddings.create(model=EMBED_MODEL, input=user_text).data[0].embedding
    rows=retrieve_hybrid(user_text, qvec, k=TOPK)
    seen=set(); uniq=[]
    for r in rows:
        if r["id"] in seen: continue
        seen.add(r["id"]); uniq.append(r)
    rows=apply_glossary_boost(user_text, uniq); rows=inject_notes(rows); rows=rerank_pairs(user_text, rows)
    blocks=[]; cites=[]; total=0; max_ctx=18000
    for i,r in enumerate(rows[:TOPK],1):
        header=f"[#{i}] {r['path']} (chunk {r['chunk_no']})"
        body=(r["content"] or "").replace("\n"," ").strip()
        piece=f"{header}\n{body}\n"
        if total+len(piece)>max_ctx: break
        blocks.append(piece); total+=len(piece)
        cites.append({"n":i,"id":r["id"],"path":r["path"],"chunk":r["chunk_no"]})
    contexts="\n---\n".join(blocks)
    prompt=(f"Pergunta: \"{user_text}\"\n\nContexto recuperado:\n{contexts}\n\n"
            "Regras:\n- Seja específico e crítico.\n- Liste prós/contras quando fizer sentido.\n"
            "- Cite fontes como [#n] + caminho.\n- Se faltar base, diga o que falta.")
    resp=client.chat.completions.create(model=GEN_MODEL,
        messages=[{"role":"system","content":SYSTEM},{"role":"user","content":prompt}],
        temperature=0.2, reasoning={"effort": REASONING_EFFORT})
    draft=resp.choices[0].message.content or "(sem conteúdo)"
    final=self_rag_verify(draft, contexts)
    return final, cites
if __name__=="__main__":
    import sys, json
    sess=sys.argv[1] if len(sys.argv)>1 else "sess"
    question=" ".join(sys.argv[2:]) if len(sys.argv)>2 else "Pergunta?"
    ans, cites = chat_respond(sess, question)
    print(json.dumps({"answer":ans, "cites":cites}, ensure_ascii=False))
PY

  # ---------------- Python: ANALYSIS TOOLS -----------------------------------
  cat > "${APP_DIR}/analyze_doc.py" <<'PY'
import os, psycopg, json, sys
from psycopg.rows import dict_row
from analyzers.legal_extractors import extract_meta
from analyzers.argument_miner import pros_cons, summary_findings
from analyzers.contradiction_finder import detect as detect_contra
from analyzers.timeline_builder import build as build_timeline
DB_URL=os.getenv("DATABASE_URL"); GEN_MODEL=os.getenv("GEN_MODEL","gpt-5")
def load_context_by_path(cur, path, k=40):
    cur.execute("SELECT id, path, chunk_no, content FROM docs WHERE path=%s ORDER BY chunk_no ASC LIMIT %s",(path,k))
    rows=cur.fetchall()
    return [{"n":i+1,"id":r["id"],"path":r["path"],"chunk":r["chunk_no"],"content":r["content"]} for i,r in enumerate(rows)]
def load_context_by_docid(cur, doc_id, k=40):
    cur.execute("SELECT path FROM docs WHERE id=%s",(doc_id,)); r=cur.fetchone()
    if not r: return []
    return load_context_by_path(cur, r["path"], k=k)
def upsert_analysis(conn, any_doc_id, path, meta, pc, sf, tl, contra, cites):
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO doc_analysis(doc_id,path,tipo,numero,data,orgao,tema,processo_sei,summary,pros,cons,findings,citations,timeline,divergences,created_at)
                       VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,now())
                       ON CONFLICT(doc_id) DO UPDATE SET
                         path=EXCLUDED.path,tipo=EXCLUDED.tipo,numero=EXCLUDED.numero,data=EXCLUDED.data,orgao=EXCLUDED.orgao,
                         tema=EXCLUDED.tema,processo_sei=EXCLUDED.processo_sei,summary=EXCLUDED.summary,pros=EXCLUDED.pros,
                         cons=EXCLUDED.cons,findings=EXCLUDED.findings,citations=EXCLUDED.citations,timeline=EXCLUDED.timeline,
                         divergences=EXCLUDED.divergences,created_at=now()""",
                    (any_doc_id, path, meta.get("tipo"), meta.get("numero"), meta.get("data"), meta.get("orgao"),
                     None, None, sf.get("summary",""), psycopg.types.json.Json(pc.get("pros",[])),
                     psycopg.types.json.Json(pc.get("cons",[])), psycopg.types.json.Json(sf.get("findings",[])),
                     psycopg.types.json.Json(cites), psycopg.types.json.Json(tl.get("timeline",[])),
                     psycopg.types.json.Json(contra)))
        conn.commit()
def main():
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--path", help="Caminho completo do documento")
    ap.add_argument("--doc_id", type=int, help="ID de um chunk em docs")
    ap.add_argument("--k", type=int, default=40)
    args=ap.parse_args()
    if not args.path and not args.doc_id:
        print("Forneça --path ou --doc_id", file=sys.stderr); sys.exit(2)
    with psycopg.connect(DB_URL, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            ctx = load_context_by_path(cur, args.path, k=args.k) if args.path else load_context_by_docid(cur, args.doc_id, k=args.k)
            if not ctx: print("Contexto vazio.", file=sys.stderr); sys.exit(1)
            text_all=" ".join([c["content"] or "" for c in ctx])
            meta=extract_meta(text_all, {})
            pc=pros_cons(ctx, GEN_MODEL)
            sf=summary_findings(ctx, GEN_MODEL)
            tl=build_timeline(ctx, GEN_MODEL)
            contra=detect_contra(ctx, GEN_MODEL)
            cites=[{"n":c["n"],"path":c["path"],"chunk":c["chunk"]} for c in ctx]
            any_doc_id=ctx[0]["id"]; path=ctx[0]["path"]
            upsert_analysis(conn, any_doc_id, path, meta, pc, sf, tl, contra, cites)
            print(json.dumps({"ok":True,"path":path,"meta":meta}, ensure_ascii=False))
if __name__=="__main__": main()
PY

  cat > "${APP_DIR}/analyze_batch.py" <<'PY'
import os, psycopg, sys, json, subprocess
from psycopg.rows import dict_row
DB_URL=os.getenv("DATABASE_URL")
def iter_paths(cur, prefix:str|None, limit:int):
    if prefix:
        cur.execute("SELECT DISTINCT path FROM docs WHERE path LIKE %s ORDER BY path ASC LIMIT %s", (prefix.rstrip('/')+'%', limit))
    else:
        cur.execute("SELECT path FROM (SELECT path, min(id) AS mid FROM docs GROUP BY path ORDER BY mid DESC LIMIT %s) t", (limit,))
    return [r["path"] for r in cur.fetchall()]
def run(prefix=None, limit=50):
    with psycopg.connect(DB_URL, row_factory=dict_row) as conn, conn.cursor() as cur:
        paths = iter_paths(cur, prefix, limit)
    ok=0
    for p in paths:
        cmd=[sys.executable, "-u", os.path.join(os.path.dirname(__file__), "analyze_doc.py"), "--path", p]
        r=subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode==0: ok+=1
        else: print(r.stderr.strip(), file=sys.stderr)
    print(json.dumps({"ok":ok,"total":len(paths)}, ensure_ascii=False))
if __name__=="__main__":
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--prefix", help="PREFIXO de caminho para filtrar", default=None)
    ap.add_argument("--limit", type=int, default=50)
    a=ap.parse_args(); run(a.prefix, a.limit)
PY

  cat > "${APP_DIR}/report_builder.py" <<'PY'
import os, psycopg
from psycopg.rows import dict_row
DB_URL=os.getenv("DATABASE_URL")
def build(prefix:str|None=None, limit:int=100):
    with psycopg.connect(DB_URL, row_factory=dict_row) as conn, conn.cursor() as cur:
        if prefix:
            cur.execute("""SELECT * FROM doc_analysis WHERE path LIKE %s ORDER BY created_at DESC LIMIT %s""",
                        (prefix.rstrip('/')+'%', limit))
        else:
            cur.execute("""SELECT * FROM doc_analysis ORDER BY created_at DESC LIMIT %s""",(limit,))
        rows=cur.fetchall()
    lines=["# Relatório de Análise",""]
    for r in rows:
        lines.append(f"## {r['path']}")
        meta=[]
        for k in ("tipo","numero","data","orgao"):
            if r.get(k): meta.append(f"**{k}**: {r[k]}")
        if meta:
            lines.append(" | ".join(meta))
        if r.get("summary"):
            lines.append("\n**Resumo:** "+(r.get("summary") or ""))
        pros = r.get("pros") or []
        if pros:
            lines.append("\n**Prós:**")
            for it in pros:
                lines.append(f"- {it.get('claim','')} — {it.get('why','')}")
        cons = r.get("cons") or []
        if cons:
            lines.append("\n**Contras:**")
            for it in cons:
                lines.append(f"- {it.get('claim','')} — {it.get('why','')}")
        timeline = r.get("timeline") or []
        if timeline:
            lines.append("\n**Linha do tempo:**")
            for ev in timeline:
                lines.append(f"- {ev.get('date','')}: {ev.get('event','')}")
        lines.append("")
    print("\n".join(lines))
if __name__=="__main__":
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--prefix", default=None); ap.add_argument("--limit", type=int, default=100)
    a=ap.parse_args(); build(a.prefix, a.limit)
PY

  # ---------------- Python: api.py (com endpoints de análise) ----------------
  cat > "${APP_DIR}/api.py" <<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import os, io, contextlib, json, subprocess, sys
from search_answer import answer as answer_single
from search_chat import chat_respond
import psycopg
DB_URL = os.getenv("DATABASE_URL")
APP_DIR = os.path.dirname(__file__)
app = FastAPI(title="Sophia RAG API", version="1.1")
class AskIn(BaseModel):
  question: str
  top_k: Optional[int] = None
class ChatIn(BaseModel):
  session: str
  message: str
class AnalyzeIn(BaseModel):
  path: Optional[str] = None
  doc_id: Optional[int] = None
  k: Optional[int] = 40
class AnalyzeBatchIn(BaseModel):
  prefix: Optional[str] = None
  limit: Optional[int] = 50
@app.get("/health")
def health():
  try:
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
      cur.execute("select 1"); cur.fetchone()
  except Exception as e:
    raise HTTPException(status_code=500, detail=f"DB error: {e}")
  return {"ok": True}
@app.post("/ask")
def ask(inp: AskIn):
  buf = io.StringIO()
  with contextlib.redirect_stdout(buf):
    answer_single(inp.question, k=inp.top_k or int(os.getenv("TOPK","12")))
  return {"answer": buf.getvalue().strip()}
@app.post("/chat")
def chat(inp: ChatIn):
  ans, cites = chat_respond(inp.session, inp.message)
  return {"answer": ans, "citations": cites}
@app.post("/analyze_doc")
def analyze_doc(inp: AnalyzeIn):
  cmd=[sys.executable, "-u", os.path.join(APP_DIR,"analyze_doc.py")]
  if inp.path: cmd += ["--path", inp.path]
  if inp.doc_id is not None: cmd += ["--doc_id", str(inp.doc_id)]
  if inp.k: cmd += ["--k", str(inp.k)]
  r=subprocess.run(cmd, capture_output=True, text=True)
  if r.returncode!=0: raise HTTPException(status_code=500, detail=r.stderr.strip())
  try: return json.loads(r.stdout.strip())
  except: return {"ok": True, "raw": r.stdout.strip()}
@app.post("/analyze_batch")
def analyze_batch(inp: AnalyzeBatchIn):
  cmd=[sys.executable, "-u", os.path.join(APP_DIR,"analyze_batch.py")]
  if inp.prefix: cmd += ["--prefix", inp.prefix]
  if inp.limit: cmd += ["--limit", str(inp.limit)]
  r=subprocess.run(cmd, capture_output=True, text=True)
  if r.returncode!=0: raise HTTPException(status_code=500, detail=r.stderr.strip())
  try: return json.loads(r.stdout.strip())
  except: return {"ok": True, "raw": r.stdout.strip()}
@app.get("/analysis")
def analysis(path: Optional[str]=None, limit: int=50):
  with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
    if path:
      cur.execute("SELECT * FROM doc_analysis WHERE path=%s", (path,)); row=cur.fetchone()
      if not row: raise HTTPException(status_code=404, detail="not found")
      cols=[d[0] for d in cur.description]
      return dict(zip(cols,row))
    else:
      cur.execute("SELECT path, summary, created_at FROM doc_analysis ORDER BY created_at DESC LIMIT %s",(limit,))
      return [{"path":p,"summary":s,"created_at":c.isoformat()} for p,s,c in cur.fetchall()]
@app.get("/report")
def report(prefix: Optional[str]=None, limit: int=100):
  cmd=[sys.executable, "-u", os.path.join(APP_DIR,"report_builder.py")]
  if prefix: cmd += ["--prefix", prefix]
  if limit: cmd += ["--limit", str(limit)]
  r=subprocess.run(cmd, capture_output=True, text=True)
  if r.returncode!=0: raise HTTPException(status_code=500, detail=r.stderr.strip())
  return {"markdown": r.stdout}
PY

  # ---------------- wrappers (bash) -----------------------------------------
  cat > "${BASE_DIR}/ask.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/app"
source .venv/bin/activate
export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed 's/\r$//')
python -u search_answer.py "$@"
SH
  chmod +x "${BASE_DIR}/ask.sh"

  cat > "${BASE_DIR}/chat_tui.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
BASE="/opt/rag-sophia"
APP="$BASE/app"
SESSION="${1:-sess_$(date +%Y%m%d_%H%M%S)}"
ensure_api_key(){
  . "$APP/.env"
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    if command -v dialog >/dev/null 2>&1; then dialog --inputbox "Informe sua OPENAI_API_KEY" 10 70 "" 2>/.tmp.key || exit 1; KEY="$(cat /.tmp.key)"
    else KEY=$(whiptail --inputbox "Informe sua OPENAI_API_KEY" 10 70 "" 3>&1 1>&2 2>&3) || exit 1; fi
    [[ -z "$KEY" ]] && exit 1
    sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$KEY/" "$APP/.env"
  fi
}
start_stack(){ systemctl start sophia-api >/dev/null 2>&1 || true; cd "$BASE"; docker compose up -d >/dev/null 2>&1 || true; }
send_question(){
  ensure_api_key
  local q ans tmp
  if command -v dialog >/dev/null 2>&1; then dialog --inputbox "Digite sua pergunta" 12 78 "" 2>/.tmp.q || return; q="$(cat /.tmp.q)"
  else q=$(whiptail --inputbox "Digite sua pergunta" 12 78 --title "💬 Nova pergunta" 3>&1 1>&2 2>&3) || return; fi
  [[ -z "$q" ]] && return
  tmp="$(mktemp)"; cd "$APP"; source .venv/bin/activate
  export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed 's/\r$//')
  python -u - "$SESSION" "$q" > "$tmp" 2>&1 <<'PY'
import sys, json
from search_chat import chat_respond
ans, cites = chat_respond(sys.argv[1], sys.argv[2])
print(json.dumps({"answer":ans, "cites":cites}, ensure_ascii=False))
PY
  if jq -e . >/dev/null 2>&1 <"$tmp"; then ans="$(jq -r '.answer' "$tmp" 2>/dev/null)"; else ans="$(tail -n 200 "$tmp")"; fi
  [[ -z "$ans" ]] && ans="(sem resposta / verifique logs)"
  if command -v dialog >/dev/null 2>&1; then dialog --msgbox "$ans" 25 100; else whiptail --scrolltext --title "🤖 Resposta" --msgbox "$ans" 25 100; fi
}
main_menu(){
  start_stack
  while true; do
    if command -v dialog >/dev/null 2>&1; then dialog --menu "💬 Sophia – Chat (sessão: $SESSION)" 20 78 10 Q "Nova pergunta" B "Voltar" 2>/.tmp.sel || exit 0; CH="$(cat /.tmp.sel)"
    else CH=$(whiptail --title "💬 Sophia – Chat (sessão: $SESSION)" --menu "Selecione:" 20 78 10 Q "Nova pergunta" B "Voltar" 3>&1 1>&2 2>&3) || exit 0; fi
    case "$CH" in Q) send_question ;; B) exit 0 ;; esac
  done
}
main_menu
SH
  chmod +x "${BASE_DIR}/chat_tui.sh"

  cat > "${BASE_DIR}/ingest_menu.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
BASE="/opt/rag-sophia"; APP="$BASE/app"; LOG="/tmp/sophia_ingest.log"
ask_delta_or_full(){
  source "$BASE/.env"; source "$APP/.env"
  read -r fi docs < <(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" rag_pg_sophia \
    psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc \
"WITH a AS (SELECT count(*) c FROM file_inventory WHERE path LIKE '${DATA_DIR}%'),
 b AS (SELECT count(*) c FROM docs WHERE path LIKE '${DATA_DIR}%')
 SELECT COALESCE((SELECT c FROM a),0)::int, COALESCE((SELECT c FROM b),0)::int;")
  if (( fi>0 || docs>0 )); then
    if command -v dialog >/dev/null 2>&1; then dialog --yesno "Registros anteriores (file_inventory=${fi}, docs=${docs}). Reaproveitar (delta)?\nNão = limpar e recomeçar." 12 78; res=$?
    else whiptail --yesno "Registros anteriores (file_inventory=${fi}, docs=${docs}). Reaproveitar (delta)?\nNão = limpar e recomeçar." 12 78; res=$?; fi
    if [[ $res -eq 0 ]]; then echo "delta"; else echo "full"; fi
  else echo "delta"; fi
}
prepare_full_or_delta(){
  local mode; mode="$(ask_delta_or_full)"
  if [[ "$mode" == "full" ]]; then
    (command -v dialog >/dev/null 2>&1 && dialog --msgbox "Limpando registros antigos…" 8 60) || whiptail --msgbox "Limpando registros antigos…" 8 60
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" rag_pg_sophia psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
"DELETE FROM feedback WHERE doc_id IN (SELECT id FROM docs WHERE path LIKE '${DATA_DIR}%');
 DELETE FROM qa_cache; DELETE FROM doc_analysis WHERE path LIKE '${DATA_DIR}%';
 DELETE FROM docs WHERE path LIKE '${DATA_DIR}%';
 DELETE FROM file_inventory WHERE path LIKE '${DATA_DIR}%';"
  fi
}
run_ingest(){
  :> "$LOG"; prepare_full_or_delta
  ( cd "$APP"; source .venv/bin/activate; export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed "s/\r$//"); PYTHONUNBUFFERED=1 python -u ingest.py >>"$LOG" 2>&1 ) & PID=$!
  (
    pct=1
    while kill -0 $PID 2>/dev/null; do
      found=$(grep -oE '[0-9]{1,3}%\|' "$LOG" | tail -n1 | tr -dc '0-9')
      [[ -n "$found" ]] && pct=$(( found>99 ? 99 : found ))
      echo $pct; echo "# Ingestão em andamento… (log abaixo)"; tail -n 5 "$LOG" 2>/dev/null; sleep 1
    done
    echo 100; echo "# Finalizado."
  ) | { if command -v dialog >/dev/null 2>&1; then dialog --gauge "📥 Ingestão (Fase 1 -> Fase 2)" 18 90 0; else whiptail --gauge "📥 Ingestão (Fase 1 -> Fase 2)" 18 90 0; fi; }
  tail -n 200 "$LOG" | sed 's/\x1b\[[0-9;]*m//g' > /tmp/sophia_ingest_tail.txt
  (command -v dialog >/dev/null 2>&1 && dialog --textbox /tmp/sophia_ingest_tail.txt 25 100) || whiptail --scrolltext --title "📜 Log resumido" --msgbox "$(cat /tmp/sophia_ingest_tail.txt)" 25 100
}
configure_ingest(){
  source "$APP/.env"
  if command -v dialog >/dev/null 2>&1; then
    dialog --menu "Ajustes rápidos" 20 78 10 \
      1 "Workers Fase 1 (atual: $MAX_WORKERS)" \
      2 "Workers OCR (atual: $OCR_WORKERS)" \
      3 "Chunk tokens (atual: $CHUNK_TOKENS)" \
      4 "Overlap tokens (atual: $CHUNK_OVERLAP)" \
      5 "Delta mode (atual: $DELTA_MODE)" \
      6 "OCR Enabled (atual: $OCR_ENABLED)" \
      7 "Voltar" 2>/.tmp.sel || return
    CH="$(cat /.tmp.sel)"
  else
    CH=$(whiptail --title "⚙️  Configurar ingestão" --menu "Ajustes rápidos" 20 78 10 \
      1 "Workers Fase 1 (atual: $MAX_WORKERS)" \
      2 "Workers OCR (atual: $OCR_WORKERS)" \
      3 "Chunk tokens (atual: $CHUNK_TOKENS)" \
      4 "Overlap tokens (atual: $CHUNK_OVERLAP)" \
      5 "Delta mode (atual: $DELTA_MODE)" \
      6 "OCR Enabled (atual: $OCR_ENABLED)" \
      7 "Voltar" 3>&1 1>&2 2>&3) || return
  fi
  case "$CH" in
    1) nw=$(inputbox "Workers Fase 1" "Valor:" "$MAX_WORKERS"); sed -i "s/^MAX_WORKERS=.*/MAX_WORKERS=$nw/" "$APP/.env" ;;
    2) nw=$(inputbox "Workers OCR" "Valor:" "$OCR_WORKERS"); sed -i "s/^OCR_WORKERS=.*/OCR_WORKERS=$nw/" "$APP/.env" ;;
    3) v=$(inputbox "Chunk tokens" "Valor:" "$CHUNK_TOKENS"); sed -i "s/^CHUNK_TOKENS=.*/CHUNK_TOKENS=$v/" "$APP/.env" ;;
    4) v=$(inputbox "Overlap tokens" "Valor:" "$CHUNK_OVERLAP"); sed -i "s/^CHUNK_OVERLAP=.*/CHUNK_OVERLAP=$v/" "$APP/.env" ;;
    5) v=$(inputbox "Delta mode" "mtime_size|sha:" "$DELTA_MODE"); sed -i "s/^DELTA_MODE=.*/DELTA_MODE=$v/" "$APP/.env" ;;
    6) v=$(inputbox "OCR Enabled" "true|false:" "$OCR_ENABLED"); sed -i "s/^OCR_ENABLED=.*/OCR_ENABLED=$v/" "$APP/.env" ;;
    7) return ;;
  esac
  if command -v dialog >/dev/null 2>&1; then dialog --msgbox "Parâmetros atualizados." 8 40; else whiptail --msgbox "Parâmetros atualizados." 8 40; fi
}
show_progress(){
  source "$BASE/.env"; source "$APP/.env"
  OUT=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" rag_pg_sophia \
    psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
"select 'total='||count(*)||' with_emb='||count(embedding)||' pending='||(count(*)-count(embedding))||' done='||coalesce(round(100.0*count(embedding)/nullif(count(*),0),2),0)||'%' from docs;")
  (command -v dialog >/dev/null 2>&1 && dialog --msgbox "$OUT" 8 68) || whiptail --msgbox "$OUT" 8 68
}
main(){
  while true; do
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "📥 Ingestão – Sophia" 20 78 10 \
        1 "Executar ingestão (Delta/Zerar + barra + log)" \
        2 "Configurar parâmetros" \
        3 "Ver progresso (docs/embeddings)" \
        4 "Voltar" 2>/.tmp.sel || exit 0
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "📥 Ingestão – Sophia" --menu "Escolha:" 20 78 10 \
        1 "Executar ingestão (Delta/Zerar + barra + log)" \
        2 "Configurar parâmetros" \
        3 "Ver progresso (docs/embeddings)" \
        4 "Voltar" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$CH" in
      1) run_ingest ;;
      2) configure_ingest ;;
      3) show_progress ;;
      4) exit 0 ;;
    esac
  done
}
main
SH
  chmod +x "${BASE_DIR}/ingest_menu.sh"

  # ---------------- TUI: Análises --------------------------------------------
  cat > "${BASE_DIR}/analyses_menu.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
BASE="/opt/rag-sophia"; APP="$BASE/app"
run_single(){
  local path
  if command -v dialog >/dev/null 2>&1; then dialog --inputbox "Caminho exato do documento (path em docs.path)" 10 80 "" 2>/.tmp.p || return; path="$(cat /.tmp.p)"
  else path=$(whiptail --inputbox "Caminho exato do documento (path em docs.path)" 10 80 "" 3>&1 1>&2 2>&3) || return; fi
  [[ -z "$path" ]] && return
  cd "$APP"; source .venv/bin/activate; export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed 's/\r$//')
  out="$(python -u analyze_doc.py --path "$path" 2>&1)"
  if command -v dialog >/dev/null 2>&1; then dialog --msgbox "$out" 25 100; else whiptail --scrolltext --title "Resultado" --msgbox "$out" 25 100; fi
}
run_batch(){
  local prefix limit
  if command -v dialog >/dev/null 2>&1; then
    dialog --inputbox "Prefixo de path (ex.: /dados/aneel/):" 10 80 "" 2>/.tmp.pr || return; prefix="$(cat /.tmp.pr)"
    dialog --inputbox "Limite de documentos:" 10 60 "30" 2>/.tmp.lm || return; limit="$(cat /.tmp.lm)"
  else
    prefix=$(whiptail --inputbox "Prefixo de path (ex.: /dados/aneel/):" 10 80 "" 3>&1 1>&2 2>&3) || return
    limit=$(whiptail --inputbox "Limite de documentos:" 10 60 "30" 3>&1 1>&2 2>&3) || return
  fi
  cd "$APP"; source .venv/bin/activate; export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed 's/\r$//')
  out="$(python -u analyze_batch.py --prefix "$prefix" --limit "${limit:-30}" 2>&1)"
  if command -v dialog >/dev/null 2>&1; then dialog --msgbox "$out" 25 100; else whiptail --scrolltext --title "Resultado" --msgbox "$out" 25 100; fi
}
run_report(){
  local prefix limit
  if command -v dialog >/dev/null 2>&1; then
    dialog --inputbox "Prefixo (opcional):" 10 80 "" 2>/.tmp.pr || return; prefix="$(cat /.tmp.pr)"
    dialog --inputbox "Limite:" 10 60 "50" 2>/.tmp.lm || return; limit="$(cat /.tmp.lm)"
  else
    prefix=$(whiptail --inputbox "Prefixo (opcional):" 10 80 "" 3>&1 1>&2 2>&3) || return
    limit=$(whiptail --inputbox "Limite:" 10 60 "50" 3>&1 1>&2 2>&3) || return
  fi
  cd "$APP"; source .venv/bin/activate; export $(grep -v '^#' .env | xargs -d '\n' -I{} echo {} | sed 's/\r$//')
  out="$(python -u report_builder.py --prefix "${prefix:-}" --limit "${limit:-50}" 2>&1)"
  if command -v dialog >/dev/null 2>&1; then printf "%s" "$out" >/tmp/report.md; dialog --textbox /tmp/report.md 25 100
  else whiptail --scrolltext --title "Relatório (markdown)" --msgbox "$out" 25 100; fi
}
main(){
  while true; do
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧠 Análises" 20 78 10 S "Analisar documento (por path)" B "Analisar em lote (por prefixo)" R "Gerar relatório (markdown)" X "Voltar" 2>/.tmp.sel || exit 0
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "🧠 Análises" --menu "Selecione:" 20 78 10 S "Analisar documento (por path)" B "Analisar em lote (por prefixo)" R "Gerar relatório (markdown)" X "Voltar" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$CH" in
      S) run_single ;;
      B) run_batch ;;
      R) run_report ;;
      X) exit 0 ;;
    esac
  done
}
main
SH
  chmod +x "${BASE_DIR}/analyses_menu.sh"

  # ---------------- Painel: menu.sh -----------------------------------------
  cat > "${BASE_DIR}/menu.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
BASE="/opt/rag-sophia"; APP="$BASE/app"; SVC="sophia-api"
validate_db(){
  source "$BASE/.env"
  out=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" rag_pg_sophia \
        psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
"select now() as ts, current_database() as db, current_user as usr;
select count(*) docs, count(embedding) with_emb from docs;" 2>&1)
  (command -v dialog >/dev/null 2>&1 && (printf "%s" "$out" > /tmp/val.txt; dialog --textbox /tmp/val.txt 25 100)) || whiptail --scrolltext --title "Validação DB/Schema" --msgbox "$out" 25 100
}
menu_api() {
  while true; do
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🌐 API – Gerenciar serviço" 15 60 6 S "Start" T "Stop" R "Restart" H "Health" B "Voltar" 2>/.tmp.sel || return
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "🌐 API" --menu "Gerenciar serviço" 15 60 6 S "Start" T "Stop" R "Restart" H "Health" B "Voltar" 3>&1 1>&2 2>&3) || return
    fi
    case "$CH" in
      S) systemctl start "$SVC" >/dev/null 2>&1 || true ;;
      T) systemctl stop "$SVC"  >/dev/null 2>&1 || true ;;
      R) systemctl restart "$SVC" >/dev/null 2>&1 || true ;;
      H) PORT="$(grep -oP '(?<=--port )\d+' /etc/systemd/system/${SVC}.service)"; out=$(curl -s "http://127.0.0.1:${PORT}/health" || echo "falhou"); (command -v dialog >/dev/null 2>&1 && dialog --msgbox "$out" 10 60) || whiptail --msgbox "$out" 10 60 ;;
      B) return ;;
    esac
  done
}
main_menu() {
  while true; do
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧭 Sophia – Painel" 20 78 12 \
        I "Instalar/ajustar dependências (TUI)" \
        D "Subir Postgres (Docker)" \
        V "Validar DB & schema (TUI)" \
        G "Ingestão detalhada (menu)" \
        N "🧠 Análises (doc, lote, relatório)" \
        T "Abrir Chat Interativo (TUI)" \
        A "API (start/stop/health)" \
        Q "Sair" 2>/.tmp.sel || exit 0
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "🧭 Sophia – Painel" --menu "Selecione:" 20 78 12 \
        I "Instalar/ajustar dependências (TUI)" \
        D "Subir Postgres (Docker)" \
        V "Validar DB & schema (TUI)" \
        G "Ingestão detalhada (menu)" \
        N "🧠 Análises (doc, lote, relatório)" \
        T "Abrir Chat Interativo (TUI)" \
        A "API (start/stop/health)" \
        Q "Sair" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$CH" in
      I) sudo "$BASE/apt_tui.sh" ;;
      D) cd "$BASE"; docker compose up -d >/dev/null 2>&1; (command -v dialog >/dev/null 2>&1 && dialog --msgbox "Postgres iniciado." 8 40) || whiptail --msgbox "Postgres iniciado." 8 40 ;;
      V) validate_db ;;
      G) "$BASE/ingest_menu.sh" ;;
      N) "$BASE/analyses_menu.sh" ;;
      T) "$BASE/chat_tui.sh" ;;
      A) menu_api ;;
      Q) exit 0 ;;
    esac
  done
}
main_menu
SH
  chmod +x "${BASE_DIR}/menu.sh"

  # ---------------- APT TUI --------------------------------------------------
  cat > "${BASE_DIR}/apt_tui.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
LOG="/tmp/sophia_apt.log"; :> "$LOG"
holds="$(apt-mark showhold 2>/dev/null || true)"
if [[ -n "$holds" ]]; then
  if command -v dialog >/dev/null 2>&1; then
    dialog --menu "Há pacotes em HOLD:\n$holds\nComo proceder?" 15 70 5 \
      C "Corrigir (remover HOLD e instalar)" I "Ignorar e continuar" X "Cancelar" 2>/.tmp.sel || exit 0
    act="$(cat /.tmp.sel)"
  else
    act=$(whiptail --title "Pacotes em HOLD" --menu "Há pacotes em HOLD:\n$holds\nComo proceder?" 15 70 5 C "Corrigir (remover HOLD e instalar)" I "Ignorar e continuar" X "Cancelar" 3>&1 1>&2 2>&3) || exit 0
  fi
  case "$act" in C) apt-mark unhold $holds >/dev/null 2>&1 || true ;; I) : ;; X) exit 0 ;; esac
fi
(
  echo ">> dpkg --configure -a" >>"$LOG"; dpkg --configure -a >>"$LOG" 2>&1 || true
  echo ">> apt -f install" >>"$LOG"; apt -f install -y >>"$LOG" 2>&1 || true
  echo ">> apt-get update" >>"$LOG"; apt-get update -y >>"$LOG" 2>&1 || true
  echo ">> resolver containerd" >>"$LOG"
  systemctl stop docker >>"$LOG" 2>&1 || true
  systemctl stop containerd >>"$LOG" 2>&1 || true
  if dpkg -l | awk "/^ii/ && /containerd\\.io/ {exit 0} END{exit 1}"; then
    apt-get purge -y containerd.io >>"$LOG" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y containerd >>"$LOG" 2>&1 || true
  fi
  FW_ON_HOLD=$(apt-mark showhold 2>/dev/null | grep -E "^firewalld$" || true)
  FW_INST=$(dpkg -l | awk "/^ii/ && /^firewalld/ {print \$2}" || true)
  EXTRA_FW="ufw"; if [[ -n "$FW_ON_HOLD" || -n "$FW_INST" ]]; then EXTRA_FW=""; fi
  echo ">> install deps" >>"$LOG"
  DEBIAN_FRONTEND=noninteractive apt-get install -y containerd docker.io docker-compose-plugin \
    python3-venv whiptail dialog jq tesseract-ocr tesseract-ocr-por tesseract-ocr-eng \
    poppler-utils util-linux curl $EXTRA_FW >>"$LOG" 2>&1 || true
  systemctl enable --now containerd >>"$LOG" 2>&1 || true
  systemctl enable --now docker >>"$LOG" 2>&1 || true
) & PID=$!
(
  pct=1
  while kill -0 $PID 2>/dev/null; do
    echo $pct; echo "# Ajustando APT e instalando dependências…"; tail -n 5 "$LOG" 2>/dev/null
    pct=$(( (pct+5) % 95 )); sleep 1
  done
  echo 100; echo "# Finalizado."
) | { if command -v dialog >/dev/null 2>&1; then dialog --gauge "Instalação de pré-requisitos" 18 90 0; else whiptail --gauge "Instalação de pré-requisitos" 18 90 0; fi; }
on_hold="$(apt-mark showhold || true)"
if [[ -n "$on_hold" ]]; then (command -v dialog >/dev/null 2>&1 && dialog --msgbox "Há pacotes em HOLD:\n${on_hold}" 12 78) || whiptail --msgbox "Há pacotes em HOLD:\n${on_hold}" 12 78
else (command -v dialog >/dev/null 2>&1 && dialog --msgbox "Dependências instaladas/ajustadas." 8 50) || whiptail --msgbox "Dependências instaladas/ajustadas." 8 50; fi
SH
  chmod +x "${BASE_DIR}/apt_tui.sh"

  # ---------------- systemd (API) -------------------------------------------
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Sophia RAG API (FastAPI + uvicorn)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/.venv/bin/uvicorn api:app --host 0.0.0.0 --port ${API_PORT} --workers 2
Restart=always
RestartSec=2
ExecStartPre=/usr/bin/bash -lc 'cd ${BASE_DIR} && docker compose up -d || true'
[Install]
WantedBy=multi-user.target
EOF

  # ---------------- .env do compose (DB) ------------------------------------
  cat > "${BASE_DIR}/.env" <<ENV
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=${DB_USER}
POSTGRES_DB=${DB_NAME}
POSTGRES_PORT=${DB_PORT}
ENV
}

#========================== SUBIR STACK & VENV ===============================#
bring_up_stack(){
  run_step "Preparando ambiente Python…" bash -lc "
    cd '${APP_DIR}' &&
    python3 -m venv .venv &&
    source .venv/bin/activate &&
    pip install --upgrade pip &&
    pip install -r requirements.txt
  " || return 1

  run_step "Subindo Postgres/pgvector (Docker)..." bash -lc "
    cd '${BASE_DIR}' &&
    docker compose up -d &&
    for i in {1..90}; do docker exec '${CONTAINER_NAME}' pg_isready -h 127.0.0.1 -p 5432 -q && break || sleep 1; done &&
    docker exec -e PGPASSWORD='${DB_PASS}' '${CONTAINER_NAME}' psql -h 127.0.0.1 -p 5432 -U '${DB_USER}' -d postgres -v ON_ERROR_STOP=1 -c \"
DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${DB_NAME}') THEN CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}; END IF; END \$\$;\" &&
    docker exec -e PGPASSWORD='${DB_PASS}' '${CONTAINER_NAME}' psql -h 127.0.0.1 -p 5432 -U '${DB_USER}' -d '${DB_NAME}' -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/001_schema.sql || true &&
    docker exec -e PGPASSWORD='${DB_PASS}' '${CONTAINER_NAME}' psql -h 127.0.0.1 -p 5432 -U '${DB_USER}' -d '${DB_NAME}' -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/002_doc_analysis.sql || true
  " || return 1

  # UFW apenas se existir e sem bloquear HTTP externo
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | head -n1 | grep -qi inactive; then
      yesno "Ativar UFW e liberar ${DB_PORT}/tcp (${UFW_CIDR}) e ${API_PORT}/tcp?" && {
        ufw allow from "${UFW_CIDR}" to any port "${DB_PORT}" proto tcp || true
        ufw allow ${API_PORT}/tcp || true
        yes | ufw enable || true
      }
    else
      ufw allow from "${UFW_CIDR}" to any port "${DB_PORT}" proto tcp || true
      ufw allow ${API_PORT}/tcp || true
    fi
  fi

  if [[ "${SKIP_SMOKE_TEST}" != "true" ]]; then
    run_step "Testando conexão com OpenAI…" bash -lc "
python - <<PY
import os
from openai import OpenAI
try:
  OpenAI(api_key=os.getenv('OPENAI_API_KEY')).chat.completions.create(model='${GEN_MODEL}',messages=[{'role':'user','content':'ping'}])
  print('OpenAI OK')
except Exception as e:
  print('OpenAI FAIL:', e)
PY
    " || true
  fi

  run_step "Ativando API (systemd)..." bash -lc "
    systemctl daemon-reload &&
    systemctl enable --now '${SERVICE_NAME}'
  " || true
}

#========================= INSTALADOR INICIAL ================================#
first_run_installer(){
  msgbox "Vamos configurar e instalar tudo agora.\nAo final você cairá no Painel."
  while true; do
    cfg_wizard
    write_files || { msgbox "Falha ao gravar arquivos."; continue; }
    apt_fix_and_install || { msgbox "Falha no APT (você pode escolher Ignorar e continuar)."; }
    bring_up_stack || msgbox "Stack não subiu completamente. Continue pelo Painel."
    break
  done
  msgbox "Instalação concluída! Entraremos no Painel."
  "${BASE_DIR}/menu.sh" || true
}

#============================== MENU INICIAL =================================#
main_menu(){
  while true; do
    CH="$(menu "Sophia RAG – Instalador & Painel" "Use setas/enter/mouse. Tudo por seleção." \
      1 "Assistente de Instalação (completo)" \
      2 "Abrir Painel (menu.sh)" \
      3 "Sair" )" || exit 0
    case "$CH" in
      1) first_run_installer ;;
      2) "${BASE_DIR}/menu.sh" || true ;;
      3) exit 0 ;;
    esac
  done
}

#==================================== RUN ====================================#
need_root
ui_detect
mkdir -p "${BASE_DIR}" "${APP_DIR}"
main_menu
