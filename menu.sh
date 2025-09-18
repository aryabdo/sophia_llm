#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/rag-sophia"
APP="$BASE/app"
ENV_FILE="$APP/.env"

show_message(){
  local title="$1" body="$2"
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "$title" --msgbox "$body" 15 80
  else
    whiptail --title "$title" --msgbox "$body" 15 80
  fi
}

confirm_action(){
  local prompt="$1"
  if command -v dialog >/dev/null 2>&1; then
    dialog --yesno "$prompt" 10 70
  else
    whiptail --yesno "$prompt" 10 70
  fi
}

load_env_var(){
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r'
  fi
}

activate_app_env(){
  source "$APP/.venv/bin/activate"
  export $(grep -v '^#' "$ENV_FILE" | xargs -d $'\n' -I{} echo {} | sed 's/\r$//')
}

cleanup_table(){
  local table="$1" label="$2"
  if ! confirm_action "Tem certeza de que deseja apagar todos os registros de $label?"; then
    return
  fi
  local db_url
  db_url="$(load_env_var "DATABASE_URL")"
  if [[ -z "$db_url" ]]; then
    show_message "Erro" "DATABASE_URL não configurada em $ENV_FILE"
    return
  fi
  activate_app_env
  local tmp
  tmp="$(mktemp)"
  python -u - "$db_url" "$table" >"$tmp" 2>&1 <<'PY'
import sys, json, psycopg

db_url, table = sys.argv[1:3]
allowed = {
    "qa_cache": "Perguntas/respostas (qa_cache)",
    "doc_analysis": "Análises de documentos (doc_analysis)",
    "notes": "Notas (notes)",
    "feedback": "Feedbacks (feedback)",
}
if table not in allowed:
    print(json.dumps({"ok": False, "error": "tabela inválida"}, ensure_ascii=False))
    sys.exit(1)
with psycopg.connect(db_url) as conn, conn.cursor() as cur:
    cur.execute(f"TRUNCATE TABLE {table} RESTART IDENTITY CASCADE;")
    conn.commit()
print(json.dumps({"ok": True, "table": table}, ensure_ascii=False))
PY
  if command -v jq >/dev/null 2>&1 && jq -e .ok >/dev/null 2>&1 <"$tmp"; then
    local status
    status="$(jq -r '.ok' <"$tmp")"
    if [[ "$status" == "true" ]]; then
      show_message "Limpeza" "Dados de $label removidos."
    else
      show_message "Limpeza" "Falha: $(jq -r '.error // "erro desconhecido"' <"$tmp")"
    fi
  else
    show_message "Limpeza" "Saída inesperada:\n$(cat "$tmp")"
  fi
  rm -f "$tmp"
}

clear_datasets(){
  local dir
  dir="$(load_env_var "FINETUNE_DIR")"
  [[ -z "$dir" ]] && dir="/opt/rag-sophia/finetune"
  if ! confirm_action "Remover arquivos de treino/validação em $dir?"; then
    return
  fi
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -type f -name 'train*.jsonl' -delete
    find "$dir" -maxdepth 1 -type f -name 'val*.jsonl' -delete
    rm -f "$dir"/train.jsonl "$dir"/val.jsonl
    show_message "Datasets" "Arquivos de treino/validação removidos."
  else
    show_message "Datasets" "Diretório $dir inexistente."
  fi
}

finetune_menu() {
  while true; do
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🎯 Treino" 18 70 8 \
        E "Exportar datasets (train/val)" \
        S "Iniciar fine-tune (OpenAI)" \
        U "Usar modelo treinado (informar ID)" \
        R "Rollback para modelo anterior" \
        B "Voltar" 2>/.tmp.sel || return
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "🎯 Treino" --menu "Selecione:" 18 70 8 \
        E "Exportar datasets (train/val)" \
        S "Iniciar fine-tune (OpenAI)" \
        U "Usar modelo treinado (informar ID)" \
        R "Rollback para modelo anterior" \
        B "Voltar" 3>&1 1>&2 2>&3) || return
    fi
    case "$CH" in
      E) /opt/rag-sophia/finetune_export.sh | tee /tmp/ft_export.log ;;
      S) /opt/rag-sophia/finetune_start.sh  | tee /tmp/ft_start.log  ;;
      U) MID=$(
            if command -v dialog >/dev/null 2>&1; then
              dialog --inputbox "Model ID (ex: ft:gpt-4o-mini:xyz)" 10 70 "" 2>/.tmp.mid || continue; cat /.tmp.mid
            else
              whiptail --inputbox "Model ID (ex: ft:gpt-4o-mini:xyz)" 10 70 "" 3>&1 1>&2 2>&3 || continue
            fi
          )
         [[ -n "$MID" ]] && /opt/rag-sophia/model_use.sh "$MID" | tee /tmp/ft_use.log ;;
      R) /opt/rag-sophia/app/.venv/bin/python -u /opt/rag-sophia/app/model_registry.py rollback | tee /tmp/ft_rollback.log
         sudo systemctl restart sophia-api || true ;;
      B) return ;;
    esac
  done
}

cleanup_menu(){
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧹 Limpeza de dados" 20 75 8 \
        Q "Apagar cache de perguntas (qa_cache)" \
        D "Apagar análises de documentos" \
        N "Apagar notas" \
        F "Apagar feedbacks" \
        X "Remover datasets de fine-tuning" \
        B "Voltar" 2>/.tmp.sel || return
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🧹 Limpeza de dados" --menu "Selecione:" 20 75 8 \
        Q "Apagar cache de perguntas (qa_cache)" \
        D "Apagar análises de documentos" \
        N "Apagar notas" \
        F "Apagar feedbacks" \
        X "Remover datasets de fine-tuning" \
        B "Voltar" 3>&1 1>&2 2>&3) || return
    fi
    case "$choice" in
      Q) cleanup_table "qa_cache" "Perguntas e respostas" ;;
      D) cleanup_table "doc_analysis" "Análises de documentos" ;;
      N) cleanup_table "notes" "Notas" ;;
      F) cleanup_table "feedback" "Feedbacks" ;;
      X) clear_datasets ;;
      B) return ;;
    esac
  done
}

main_menu(){
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧭 Sophia – Console" 20 80 8 \
        C "Abrir chat (TUI)" \
        T2 "Treino (exportar/rodar/rollback)" \
        L "Limpeza de dados" \
        Q "Sair" 2>/.tmp.sel || exit 0
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🧭 Sophia – Console" --menu "Selecione:" 20 80 8 \
        C "Abrir chat (TUI)" \
        T2 "Treino (exportar/rodar/rollback)" \
        L "Limpeza de dados" \
        Q "Sair" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$choice" in
      C) /opt/rag-sophia/chat_tui.sh ;;
      T2) finetune_menu ;;
      L) cleanup_menu ;;
      Q) exit 0 ;;
    esac
  done
}

main_menu
