#!/usr/bin/env bash
set -uo pipefail

BASE="/opt/rag-sophia"
APP="$BASE/app"
SESSION="${1:-sess_$(date +%Y%m%d_%H%M%S)}"
LAST_RESULT_JSON=""
API_ENDPOINT=""
LOG_DIR="$BASE/logs"
SAFE_SESSION="${SESSION//[^A-Za-z0-9_]/_}"
CHAT_LOG="$LOG_DIR/chat_${SAFE_SESSION}_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"

timestamp(){
  date '+%Y-%m-%d %H:%M:%S'
}

log_line(){
  printf '[%s] %s\n' "$(timestamp)" "$1" >>"$CHAT_LOG"
}

ensure_api_key(){
  if [[ -f "$APP/.env" ]]; then
    set +u
    # shellcheck disable=SC1090
    . "$APP/.env"
    set -u
  fi
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    if command -v dialog >/dev/null 2>&1; then
      dialog --inputbox "Informe sua OPENAI_API_KEY" 10 70 "" 2>/.tmp.key || exit 1
      KEY="$(cat /.tmp.key)"
    else
      KEY=$(whiptail --inputbox "Informe sua OPENAI_API_KEY" 10 70 "" 3>&1 1>&2 2>&3) || exit 1
    fi
    [[ -z "$KEY" ]] && exit 1
    sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$KEY/" "$APP/.env"
    log_line "OPENAI_API_KEY atualizado via interface"
  fi
}

start_stack(){
  systemctl start sophia-api >/dev/null 2>&1 || true
  cd "$BASE"
  docker compose up -d >/dev/null 2>&1 || true
}

show_box(){
  local title="$1" body="$2"
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "$title" --msgbox "$body" 25 100
  else
    whiptail --scrolltext --title "$title" --msgbox "$body" 25 100
  fi
}

show_alert(){
  local title="$1" body="$2"
  if command -v dialog >/dev/null 2>&1; then
    dialog --title "$title" --msgbox "$body" 12 80
  else
    whiptail --title "$title" --msgbox "$body" 12 80
  fi
}

show_progress(){
  local message="$1"
  if command -v dialog >/dev/null 2>&1; then
    dialog --infobox "$message" 7 70
  else
    whiptail --infobox "$message" 7 70
  fi
  sleep 1
}

detect_api_url(){
  if [[ -n "${API_URL:-}" ]]; then
    API_ENDPOINT="${API_URL%%/}"
    return
  fi
  if [[ -n "${API_PORT:-}" ]]; then
    API_ENDPOINT="http://127.0.0.1:${API_PORT}"
    return
  fi
  if [[ -f "$APP/.env" ]]; then
    local from_env
    from_env="$(grep -E '^API_URL=' "$APP/.env" | tail -n1 | cut -d= -f2-)"
    if [[ -n "$from_env" ]]; then
      API_ENDPOINT="${from_env%%/}"
      return
    fi
    from_env="$(grep -E '^API_PORT=' "$APP/.env" | tail -n1 | cut -d= -f2-)"
    if [[ -n "$from_env" ]]; then
      API_ENDPOINT="http://127.0.0.1:${from_env}"
      return
    fi
  fi
  API_ENDPOINT="http://127.0.0.1:18888"
}

send_question(){
  ensure_api_key
  local q ans tmp
  if command -v dialog >/dev/null 2>&1; then
    dialog --inputbox "Digite sua pergunta" 12 78 "" 2>/.tmp.q || return
    q="$(cat /.tmp.q)"
  else
    q=$(whiptail --inputbox "Digite sua pergunta" 12 78 --title "💬 Nova pergunta" 3>&1 1>&2 2>&3) || return
  fi
  [[ -z "$q" ]] && return
  log_line "Pergunta enviada: $q"
  tmp="$(mktemp)"
  cd "$APP"
  source .venv/bin/activate
  if [[ -f .env ]]; then
    set +u
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    set -u
  fi
  show_progress "Consultando Sophia..."
  python -u - "$SESSION" "$q" > "$tmp" 2>&1 <<'PY'
import sys, json
from search_chat import chat_respond
ans, cites, qhash = chat_respond(sys.argv[1], sys.argv[2])
print(json.dumps({"answer": ans, "cites": cites, "query_hash": qhash}, ensure_ascii=False))
PY
  if jq -e . >/dev/null 2>&1 <"$tmp"; then
    LAST_RESULT_JSON="$(cat "$tmp")"
    ans="$(printf '%s' "$LAST_RESULT_JSON" | jq -r '.answer' 2>/dev/null)"
    log_line "Resposta recebida: ${ans//$'\n'/ }"
  else
    LAST_RESULT_JSON=""
    ans="$(tail -n 200 "$tmp")"
    log_line "Falha ao obter resposta: ${ans//$'\n'/ }"
  fi
  [[ -z "$ans" ]] && ans="(sem resposta / verifique logs)"
  show_box "🤖 Resposta" "$ans"
  rm -f "$tmp"
}

choose_from_menu(){
  local title="$1" prompt="$2"; shift 2
  local choice
  if command -v dialog >/dev/null 2>&1; then
    choice=$(dialog --stdout --title "$title" --menu "$prompt" 22 90 10 "$@") || return 1
  else
    choice=$(whiptail --title "$title" --menu "$prompt" 22 90 10 "$@" 3>&1 1>&2 2>&3) || return 1
  fi
  printf '%s' "$choice"
}

send_feedback(){
  if [[ -z "$LAST_RESULT_JSON" ]]; then
    show_alert "Feedback" "Envie uma pergunta antes de registrar feedback."
    return
  fi
  local qhash
  qhash="$(printf '%s' "$LAST_RESULT_JSON" | jq -r '.query_hash // empty')"
  if [[ -z "$qhash" ]]; then
    show_alert "Feedback" "Resposta atual não possui identificador de consulta."
    return
  fi
  local cites_json
  cites_json="$(printf '%s' "$LAST_RESULT_JSON" | jq -c '.cites // .citations // []')"
  if [[ "$(printf '%s' "$cites_json" | jq 'length')" -eq 0 ]]; then
    show_alert "Feedback" "Resposta atual não possui citações para avaliar."
    return
  fi
  local menu_items=()
  while IFS=$'\n' read -r line; do
    [[ -z "$line" ]] && continue
    local doc_id="${line%%|*}"
    local label="${line#*|}"
    menu_items+=("$doc_id" "$label")
  done < <(printf '%s' "$cites_json" | jq -r '.[] | "\(.id)|[#\(.n)] \(.path) (chunk \(.chunk))"')
  if [[ ${#menu_items[@]} -eq 0 ]]; then
    show_alert "Feedback" "Não foi possível montar a lista de citações."
    return
  fi
  local selected
  selected=$(choose_from_menu "Feedback" "Escolha o trecho para avaliar" "${menu_items[@]}") || return
  if ! [[ "$selected" =~ ^[0-9]+$ ]]; then
    show_alert "Feedback" "Identificador de chunk inválido: $selected"
    return
  fi
  local signal_choice
  signal_choice=$(choose_from_menu "Feedback" "Selecione o tipo" \
    P "+1 Relevante" N "-1 Não relevante" Z "Neutro (0)") || return
  local signal
  case "$signal_choice" in
    P) signal=1 ;;
    N) signal=-1 ;;
    Z) signal=0 ;;
    *) signal=0 ;;
  esac
  detect_api_url
  local payload tmp_resp curl_output http_code body
  payload=$(jq -nc --arg q "$qhash" --argjson d "$selected" --argjson s "$signal" '{query_hash:$q, doc_id:$d, signal:$s}')
  tmp_resp="$(mktemp)"
  curl_output=$(curl -sS -o "$tmp_resp" -w '%{http_code}' -X POST "${API_ENDPOINT%/}/feedback" \
    -H 'Content-Type: application/json' -d "$payload" 2>&1)
  local curl_status=$?
  if [[ $curl_status -ne 0 ]]; then
    rm -f "$tmp_resp"
    show_alert "Feedback" "Falha ao enviar: ${curl_output:-erro desconhecido}"
    return
  fi
  http_code="${curl_output:(-3)}"
  http_code="${http_code//$'\n'/}"; http_code="${http_code//$'\r'/}"
  body="$(cat "$tmp_resp")"
  rm -f "$tmp_resp"
  if [[ "$http_code" =~ ^2 && ( -z "$body" || $(printf '%s' "$body" | jq -r '.ok // empty' 2>/dev/null) == "true" ) ]]; then
    show_alert "Feedback" "Obrigado! Feedback registrado."
    log_line "Feedback enviado para doc $selected com sinal $signal"
  else
    show_alert "Feedback" "Erro ${http_code}: ${body:-sem resposta}"
    log_line "Erro ao enviar feedback (HTTP ${http_code}): ${body:-sem resposta}"
  fi
}

main_menu(){
  start_stack
  while true; do
    local CH
    if command -v dialog >/dev/null 2>&1; then
      dialog --menu "💬 Sophia – Chat (sessão: $SESSION)" 20 78 10 \
        Q "Nova pergunta" F "Enviar feedback" B "Voltar" 2>/.tmp.sel || exit 0
      CH="$(cat /.tmp.sel)"
    else
      CH=$(whiptail --title "💬 Sophia – Chat (sessão: $SESSION)" --menu "Selecione:" 20 78 10 \
        Q "Nova pergunta" F "Enviar feedback" B "Voltar" 3>&1 1>&2 2>&3) || exit 0
    fi
    case "$CH" in
      Q) send_question ;;
      F) send_feedback ;;
      B) exit 0 ;;
    esac
  done
}

main_menu
