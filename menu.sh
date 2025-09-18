#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/rag-sophia"
APP="$BASE/app"
ENV_FILE="$APP/.env"
LOG_DIR="$BASE/logs"
ACTION_LOG="$LOG_DIR/actions.log"
LAST_LOG=""

mkdir -p "$LOG_DIR"

timestamp(){
  date '+%Y-%m-%d %H:%M:%S'
}

show_message(){
  local title="$1" body="$2"
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "$title" --msgbox "$body" 15 80
  else
    whiptail --title "$title" --msgbox "$body" 15 80
  fi
}

show_textbox(){
  local title="$1" file="$2"
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "$title" --textbox "$file" 25 100
  else
    whiptail --scrolltext --title "$title" --textbox "$file" 25 100
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
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

ensure_log_dir(){
  mkdir -p "$LOG_DIR"
}

log_event(){
  ensure_log_dir
  printf '[%s] %s\n' "$(timestamp)" "$1" >>"$ACTION_LOG"
}

run_and_log(){
  local label="$1" logfile cmd_status
  shift
  ensure_log_dir
  logfile="$LOG_DIR/$(date '+%Y%m%d_%H%M%S')_${label}.log"
  LAST_LOG="$logfile"
  local start_msg
  start_msg="[$(timestamp)] Iniciando ${label}"
  set +e
  {
    echo "$start_msg"
    "$@"
  } 2>&1 | tee "$logfile"
  cmd_status=${PIPESTATUS[0]}
  set -e
  printf '[%s] Finalizado com status %s\n' "$(timestamp)" "$cmd_status" >>"$logfile"
  if [[ $cmd_status -eq 0 ]]; then
    log_event "${label}: concluído (log: ${logfile})"
    show_message "${label}" "Operação concluída. Logs: $logfile"
  else
    log_event "${label}: falhou (log: ${logfile})"
    show_message "${label}" "Falha (código $cmd_status). Consulte o log:\n$logfile"
  fi
  return $cmd_status
}

show_last_log(){
  if [[ -z "$LAST_LOG" ]]; then
    show_message "Logs" "Nenhuma operação foi executada nesta sessão."
    return
  fi
  if [[ ! -f "$LAST_LOG" ]]; then
    show_message "Logs" "Último log não encontrado em $LAST_LOG"
    return
  fi
  show_textbox "Último log" "$LAST_LOG"
}

select_and_show_log(){
  ensure_log_dir
  mapfile -t logs < <(ls -1t "$LOG_DIR"/*.log 2>/dev/null || true)
  if [[ ${#logs[@]} -eq 0 ]]; then
    show_message "Logs" "Nenhum log disponível em $LOG_DIR"
    return
  fi
  local entries=()
  for i in "${!logs[@]}"; do
    local idx=$((i + 1))
    entries+=("$idx" "$(basename "${logs[$i]}")")
  done
  local choice
  if command -v dialog >/dev/null 2>&1; then
    dialog --menu "Selecione o log para visualizar" 20 90 10 "${entries[@]}" 2>/.tmp.sel || return
    choice="$(cat /.tmp.sel)"
  else
    choice=$(whiptail --title "Logs" --menu "Selecione o log" 20 90 10 "${entries[@]}" 3>&1 1>&2 2>&3) || return
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    show_message "Logs" "Seleção inválida: $choice"
    return
  fi
  local idx=$((choice - 1))
  if (( idx < 0 || idx >= ${#logs[@]} )); then
    show_message "Logs" "Índice fora do intervalo: $choice"
    return
  fi
  show_textbox "Log: $(basename "${logs[$idx]}")" "${logs[$idx]}"
}

show_action_history(){
  ensure_log_dir
  if [[ ! -f "$ACTION_LOG" ]]; then
    show_message "Histórico" "Nenhuma ação registrada até o momento."
    return
  fi
  show_textbox "Histórico de ações" "$ACTION_LOG"
}

show_service_logs(){
  if ! command -v journalctl >/dev/null 2>&1; then
    show_message "Logs" "journalctl não está disponível nesta máquina."
    return
  fi
  local tmp
  tmp="$(mktemp)"
  if ! journalctl -u sophia-api --no-pager -n 200 >"$tmp" 2>&1; then
    show_message "Logs" "Não foi possível recuperar logs do serviço sophia-api."
    rm -f "$tmp"
    return
  fi
  show_textbox "journalctl -u sophia-api (últimos 200 registros)" "$tmp"
  rm -f "$tmp"
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
      log_event "Limpeza concluída para $label"
    else
      show_message "Limpeza" "Falha: $(jq -r '.error // \"erro desconhecido\"' <"$tmp")"
      log_event "Limpeza falhou para $label"
    fi
  else
    show_message "Limpeza" "Saída inesperada:\n$(cat "$tmp")"
    log_event "Limpeza com saída inesperada para $label"
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
    log_event "Datasets de fine-tuning removidos em $dir"
  else
    show_message "Datasets" "Diretório $dir inexistente."
    log_event "Tentativa de remover datasets em diretório inexistente $dir"
  fi
}

finetune_menu() {
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🎯 Treino e modelos" 20 78 8 \
        E "Exportar datasets (train/val)" \
        S "Iniciar fine-tune (OpenAI)" \
        U "Usar modelo treinado (informar ID)" \
        R "Rollback para modelo anterior" \
        B "Voltar" 2>/.tmp.sel || return
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🎯 Treino e modelos" --menu "Selecione:" 20 78 8 \
        E "Exportar datasets (train/val)" \
        S "Iniciar fine-tune (OpenAI)" \
        U "Usar modelo treinado (informar ID)" \
        R "Rollback para modelo anterior" \
        B "Voltar" 3>&1 1>&2 2>&3) || return
    fi
    case "$choice" in
      E)
        run_and_log "finetune_export" /opt/rag-sophia/finetune_export.sh
        ;;
      S)
        run_and_log "finetune_start" /opt/rag-sophia/finetune_start.sh
        ;;
      U)
        local mid
        mid=$( \
            if command -v dialog >/dev/null 2>&1; then
              dialog --inputbox "Model ID (ex: ft:gpt-4o-mini:xyz)" 10 70 "" 2>/.tmp.mid || continue; cat /.tmp.mid
            else
              whiptail --inputbox "Model ID (ex: ft:gpt-4o-mini:xyz)" 10 70 "" 3>&1 1>&2 2>&3 || continue
            fi
          )
        if [[ -n "$mid" ]]; then
          run_and_log "model_use" /opt/rag-sophia/model_use.sh "$mid"
        fi
        ;;
      R)
        run_and_log "model_rollback" bash -c '
          /opt/rag-sophia/app/.venv/bin/python -u /opt/rag-sophia/app/model_registry.py rollback && {
            echo "Reiniciando sophia-api"
            sudo systemctl restart sophia-api || true
          }
        '
        ;;
      B)
        return
        ;;
    esac
  done
}

cleanup_menu(){
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧹 Dados e limpeza" 20 75 8 \
        Q "Apagar cache de perguntas (qa_cache)" \
        D "Apagar análises de documentos" \
        N "Apagar notas" \
        F "Apagar feedbacks" \
        X "Remover datasets de fine-tuning" \
        B "Voltar" 2>/.tmp.sel || return
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🧹 Dados e limpeza" --menu "Selecione:" 20 75 8 \
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


tools_menu(){
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🛠️ Ferramentas e logs" 20 80 8 \
        L "Ver último log desta sessão" \
        A "Histórico de ações" \
        S "Selecionar log para visualizar" \
        J "Logs do serviço sophia-api" \
        B "Voltar" 2>/.tmp.sel || return
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🛠️ Ferramentas e logs" --menu "Selecione:" 20 80 8 \
        L "Ver último log desta sessão" \
        A "Histórico de ações" \
        S "Selecionar log para visualizar" \
        J "Logs do serviço sophia-api" \
        B "Voltar" 3>&1 1>&2 2>&3) || return
    fi
    case "$choice" in
      L) show_last_log ;;
      A) show_action_history ;;
      S) select_and_show_log ;;
      J) show_service_logs ;;
      B) return ;;
    esac
  done
}


main_menu(){
  while true; do
    local choice
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "🧭 Sophia – Console" 22 85 8 \
        C "Abrir chat (TUI)" \
        T "Treino e modelos" \
        D "Dados e limpeza" \
        F "Ferramentas e logs" \
        Q "Sair" 2>/.tmp.sel || exit 0
      choice="$(cat /.tmp.sel)"
    else
      choice=$(whiptail --title "🧭 Sophia – Console" --menu "Selecione:" 22 85 8 \
        C "Abrir chat (TUI)" \
        T "Treino e modelos" \
        D "Dados e limpeza" \
        F "Ferramentas e logs" \
        Q "Sair" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$choice" in
      C) /opt/rag-sophia/chat_tui.sh ;;
      T) finetune_menu ;;
      D) cleanup_menu ;;
      F) tools_menu ;;
      Q) exit 0 ;;
    esac
  done
}


main_menu
