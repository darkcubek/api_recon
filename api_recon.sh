#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "$0")"
DOMAIN=""
SUBDOMAINS_FILE=""
OUTPUT_DIR=""
THREADS=20
FFUF_CODES="200,201,204,301,302,307,308,400,401,403,405"
HTTPX_CODES="200,201,204,301,302,307,308,400,401,403,405"
INSTALL_TOOLS=0
AUTHORIZED=0
INSECURE=0
DOWNLOAD_SPECS=1

usage() {
  cat <<EOF
Использование:
  $SCRIPT_NAME --authorized -d example.com [параметры]

Обязательные параметры:
  -d, --domain DOMAIN          Корневой домен без пути, например example.com
  --authorized                Подтверждение, что у вас есть разрешение на тестирование

Дополнительные параметры:
  -s, --subdomains FILE        Файл с субдоменами, по одному в строке
  -o, --output DIR             Каталог результатов
  -t, --threads N              Потоки ffuf/httpx, по умолчанию: 20, максимум: 50
  --insecure                   Не проверять TLS-сертификаты в ffuf/curl
  --no-download-specs          Не скачивать найденные Swagger/OpenAPI-файлы
  --install-tools              Попытаться установить jq, curl, ffuf, gau,
                               waybackurls и ProjectDiscovery httpx
  -h, --help                   Показать эту справку

Примеры:
  chmod +x $SCRIPT_NAME
  ./$SCRIPT_NAME --authorized -d example.com
  ./$SCRIPT_NAME --authorized -d example.com -s subdomains.txt -t 15

Результаты сохраняются в отдельный каталог. Скрипт не эксплуатирует
уязвимости, не перебирает учётные данные и не отправляет изменяющие запросы.
EOF
}

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

cleanup_domain() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  value="${value#.}"
  value="${value%.}"
  printf '%s' "${value,,}"
}

valid_domain() {
  local value="$1"
  [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

host_in_scope() {
  local host="${1,,}"
  [[ "$host" == "$DOMAIN" || "$host" == *."$DOMAIN" ]]
}

safe_filename() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9._-]+#_#g; s#^_+|_+$##g'
}

resolve_tool() {
  local name="$1"
  local candidate
  for candidate in "$HOME/go/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  command -v "$name" 2>/dev/null || return 1
}

install_tools() {
  log "Установка системных зависимостей..."
  command -v sudo >/dev/null 2>&1 || die "Для --install-tools необходим sudo."
  sudo apt-get update
  sudo apt-get install -y jq curl ca-certificates golang-go ffuf

  command -v go >/dev/null 2>&1 || die "Go не установлен."
  export PATH="$PATH:$HOME/go/bin"

  log "Установка gau..."
  go install github.com/lc/gau/v2/cmd/gau@latest
  log "Установка waybackurls..."
  go install github.com/tomnomnom/waybackurls@latest
  log "Установка ProjectDiscovery httpx..."
  go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
}

while (($#)); do
  case "$1" in
    -d|--domain)
      [[ $# -ge 2 ]] || die "После $1 нужен домен."
      DOMAIN="$2"
      shift 2
      ;;
    -s|--subdomains)
      [[ $# -ge 2 ]] || die "После $1 нужен путь к файлу."
      SUBDOMAINS_FILE="$2"
      shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 ]] || die "После $1 нужен каталог."
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -t|--threads)
      [[ $# -ge 2 ]] || die "После $1 нужно число."
      THREADS="$2"
      shift 2
      ;;
    --authorized)
      AUTHORIZED=1
      shift
      ;;
    --insecure)
      INSECURE=1
      shift
      ;;
    --no-download-specs)
      DOWNLOAD_SPECS=0
      shift
      ;;
    --install-tools)
      INSTALL_TOOLS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Неизвестный параметр: $1. Используйте --help."
      ;;
  esac
done

[[ "$AUTHORIZED" -eq 1 ]] || die "Запуск отменён: добавьте --authorized только при наличии разрешения владельца системы."
[[ -n "$DOMAIN" ]] || die "Не указан домен. Используйте -d example.com."
DOMAIN="$(cleanup_domain "$DOMAIN")"
valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"
[[ "$THREADS" =~ ^[0-9]+$ ]] || die "--threads должен быть целым числом."
(( THREADS >= 1 && THREADS <= 50 )) || die "--threads должен быть от 1 до 50."

if [[ -n "$SUBDOMAINS_FILE" && ! -r "$SUBDOMAINS_FILE" ]]; then
  die "Не удаётся прочитать файл субдоменов: $SUBDOMAINS_FILE"
fi

if [[ "$INSTALL_TOOLS" -eq 1 ]]; then
  install_tools
fi

GAU_BIN="$(resolve_tool gau || true)"
WAYBACK_BIN="$(resolve_tool waybackurls || true)"
FFUF_BIN="$(resolve_tool ffuf || true)"
HTTPX_BIN="$(resolve_tool httpx || true)"
JQ_BIN="$(resolve_tool jq || true)"
CURL_BIN="$(resolve_tool curl || true)"

[[ -n "$GAU_BIN" ]] || die "Не найден gau. Повторите с --install-tools или установите его вручную."
[[ -n "$WAYBACK_BIN" ]] || die "Не найден waybackurls. Повторите с --install-tools или установите его вручную."
[[ -n "$FFUF_BIN" ]] || die "Не найден ffuf. Повторите с --install-tools или: sudo apt install ffuf"
[[ -n "$HTTPX_BIN" ]] || die "Не найден ProjectDiscovery httpx. Повторите с --install-tools."
[[ -n "$JQ_BIN" ]] || die "Не найден jq. Установите: sudo apt install jq"
[[ -n "$CURL_BIN" ]] || die "Не найден curl. Установите: sudo apt install curl"

# Защита от случайного выбора Python-пакета httpx вместо ProjectDiscovery httpx.
# Не используем grep -q вместе с pipefail: grep может закрыть pipe после первого
# совпадения, httpx получит SIGPIPE, и корректный бинарник будет ошибочно отклонён.
HTTPX_HELP="$("$HTTPX_BIN" -h 2>&1 || true)"
if ! grep -iE 'projectdiscovery|http toolkit|status-code|tech-detect' <<< "$HTTPX_HELP" >/dev/null; then
  HTTPX_VERSION="$("$HTTPX_BIN" -version 2>&1 || true)"
  if ! grep -iE 'httpx|projectdiscovery' <<< "$HTTPX_VERSION" >/dev/null; then
    die "Команда '$HTTPX_BIN' не похожа на ProjectDiscovery httpx. Проверка: $HTTPX_BIN -version"
  fi
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="api_recon_${DOMAIN}_${TIMESTAMP}"
fi
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

HIST_DIR="$OUTPUT_DIR/historical"
FFUF_DIR="$OUTPUT_DIR/ffuf"
CAND_DIR="$OUTPUT_DIR/candidates"
SPECS_DIR="$OUTPUT_DIR/specs"
LOG_DIR="$OUTPUT_DIR/logs"
mkdir -p "$HIST_DIR" "$FFUF_DIR" "$CAND_DIR" "$SPECS_DIR" "$LOG_DIR"

GAU_FILE="$HIST_DIR/gau.txt"
WAYBACK_FILE="$HIST_DIR/waybackurls.txt"
ALL_URLS="$HIST_DIR/all_urls.txt"
API_CANDIDATES="$HIST_DIR/api_candidates.txt"
HOSTS_FILE="$OUTPUT_DIR/hosts_in_scope.txt"
WORDLIST="$OUTPUT_DIR/api_wordlist.txt"
FFUF_RAW="$CAND_DIR/ffuf_hits_raw.txt"
FFUF_HITS="$CAND_DIR/ffuf_hits.txt"
ALL_CANDIDATES="$CAND_DIR/all_candidates.txt"
HTTPX_JSON="$CAND_DIR/httpx_results.jsonl"
ACTIVE_HITS="$CAND_DIR/active_hits.txt"
PRIORITY_HITS="$CAND_DIR/priority_hits.txt"
AUTH_HITS="$CAND_DIR/auth_login_token.txt"
API_DOC_HITS="$CAND_DIR/swagger_openapi_docs.txt"
INTERNAL_HITS="$CAND_DIR/internal_debug.txt"
SUMMARY="$OUTPUT_DIR/summary.txt"

cat > "$WORDLIST" <<'EOF'
swagger.json
swagger.yaml
openapi.json
openapi.yaml
v2/api-docs
api-docs
swagger-ui
swagger-ui.html
swagger-ui/index.html
docs
redoc
api
v1
v2
v3
auth
login
token
oauth
openid
admin/api
internal-api
internal
debug
health
healthz
status
actuator
actuator/health
EOF

# Главный домен всегда входит в активную область.
printf '%s\n' "$DOMAIN" > "$HOSTS_FILE"

# Добавляем только субдомены того же корневого домена.
if [[ -n "$SUBDOMAINS_FILE" ]]; then
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%%#*}"
    raw="$(printf '%s' "$raw" | xargs)"
    [[ -n "$raw" ]] || continue
    host="$(cleanup_domain "$raw")"
    if valid_domain "$host" && host_in_scope "$host"; then
      printf '%s\n' "$host"
    else
      warn "Пропущен хост вне области или с ошибкой: $raw"
    fi
  done < "$SUBDOMAINS_FILE" >> "$HOSTS_FILE"
fi
sort -u -o "$HOSTS_FILE" "$HOSTS_FILE"

log "Область: $DOMAIN"
log "Хостов для активной проверки: $(wc -l < "$HOSTS_FILE" | tr -d ' ')"
log "Каталог результатов: $OUTPUT_DIR"

log "1/6: Сбор исторических URL через gau..."
# --subs повторяет логику статьи и включает исторические URL субдоменов.
"$GAU_BIN" "$DOMAIN" --subs > "$GAU_FILE" 2> "$LOG_DIR/gau.stderr.log" || warn "gau завершился с ошибкой; смотрите logs/gau.stderr.log"

log "2/6: Сбор URL через Wayback Machine..."
printf '%s\n' "$DOMAIN" | "$WAYBACK_BIN" > "$WAYBACK_FILE" 2> "$LOG_DIR/waybackurls.stderr.log" || warn "waybackurls завершился с ошибкой; смотрите logs/waybackurls.stderr.log"

cat "$GAU_FILE" "$WAYBACK_FILE" 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u > "$ALL_URLS"

grep -iE '/api(/|$)|/v[0-9]+(/|$)|/auth(/|$)|/token|/login|/oauth|/openid|/swagger|/openapi|/api-docs|/docs|/redoc|/admin' \
  "$ALL_URLS" | sort -u > "$API_CANDIDATES" || true

log "Исторических URL: $(wc -l < "$ALL_URLS" | tr -d ' ')"
log "API-кандидатов: $(wc -l < "$API_CANDIDATES" | tr -d ' ')"

choose_scheme() {
  local host="$1"
  local curl_tls=()
  [[ "$INSECURE" -eq 1 ]] && curl_tls=(-k)

  if "$CURL_BIN" "${curl_tls[@]}" -sS -o /dev/null --connect-timeout 5 --max-time 8 "https://$host/"; then
    printf 'https'
  elif "$CURL_BIN" -sS -o /dev/null --connect-timeout 5 --max-time 8 "http://$host/"; then
    printf 'http'
  else
    # HTTPS остаётся безопасным значением по умолчанию; ffuf запишет ошибку в лог.
    printf 'https'
  fi
}

run_ffuf() {
  local host="$1"
  local base_path="$2"
  local label="$3"
  local scheme="$4"
  local host_name
  local ffuf_tls=()
  host_name="$(safe_filename "$host")"
  [[ "$INSECURE" -eq 1 ]] && ffuf_tls=(-k)

  log "ffuf: $scheme://$host$base_path/FUZZ"
  "$FFUF_BIN" \
    -u "$scheme://$host$base_path/FUZZ" \
    -w "$WORDLIST" \
    -mc "$FFUF_CODES" \
    -t "$THREADS" \
    -timeout 10 \
    -noninteractive \
    -s \
    "${ffuf_tls[@]}" \
    -o "$FFUF_DIR/${host_name}_${label}.json" \
    -of json \
    > "$LOG_DIR/${host_name}_${label}.stdout.log" \
    2> "$LOG_DIR/${host_name}_${label}.stderr.log" || true
}

log "3/6: Активная проверка известных API-путей через ffuf..."
while IFS= read -r host; do
  [[ -n "$host" ]] || continue
  scheme="$(choose_scheme "$host")"
  run_ffuf "$host" "" "root" "$scheme"
  run_ffuf "$host" "/api" "api" "$scheme"
  sleep 0.25
done < "$HOSTS_FILE"

: > "$FFUF_RAW"
shopt -s nullglob
for json_file in "$FFUF_DIR"/*.json; do
  [[ -s "$json_file" ]] || continue
  "$JQ_BIN" -r '.results[]?.url // empty' "$json_file" 2>/dev/null >> "$FFUF_RAW" || true
done
shopt -u nullglob
sort -u "$FFUF_RAW" > "$FFUF_HITS"

log "Найдено уникальных URL через ffuf: $(wc -l < "$FFUF_HITS" | tr -d ' ')"

log "4/6: Объединение кандидатов и проверка через ProjectDiscovery httpx..."

# Раньше httpx проверял только FFUF_HITS. Из-за этого URL, найденные gau/wayback,
# не могли попасть ни в active_hits.txt, ни в priority_hits.txt.
# Объединяем оба источника и оставляем только http(s)-URL внутри разрешённой области.
{
  cat "$API_CANDIDATES" "$FFUF_HITS" 2>/dev/null || true
} | sed '/^[[:space:]]*$/d' | sort -u | while IFS= read -r url; do
  [[ "$url" =~ ^https?:// ]] || continue
  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  host="${host,,}"
  host_in_scope "$host" && printf '%s\n' "$url"
done > "$ALL_CANDIDATES"

log "Всего уникальных кандидатов для httpx: $(wc -l < "$ALL_CANDIDATES" | tr -d ' ')"

: > "$ACTIVE_HITS"
: > "$HTTPX_JSON"

if [[ -s "$ALL_CANDIDATES" ]]; then
  # JSON-режим нужен, чтобы не зависеть от форматирования обычного вывода httpx
  # и надёжно получить финальный URL и HTTP-код.
  "$HTTPX_BIN" \
    -l "$ALL_CANDIDATES" \
    -silent \
    -json \
    -t "$THREADS" \
    -o "$HTTPX_JSON" \
    2> "$LOG_DIR/httpx_active.stderr.log" || true

  # Оставляем отвечающие URL с интересующими нас кодами.
  # В разных версиях httpx финальный адрес может называться url или input,
  # поэтому предусмотрены оба поля.
  "$JQ_BIN" -r --arg codes "$HTTPX_CODES" '
    ($codes | split(",") | map(tonumber)) as $allowed
    | select(.status_code as $s | $allowed | index($s))
    | (.url // .input // empty)
  ' "$HTTPX_JSON" 2>> "$LOG_DIR/httpx_active.stderr.log" \
    | sed '/^[[:space:]]*$/d' \
    | sort -u > "$ACTIVE_HITS" || true

  log "Ответов, записанных httpx в JSONL: $(wc -l < "$HTTPX_JSON" | tr -d ' ')"
else
  warn "Нет кандидатов для httpx: $ALL_CANDIDATES пуст."
fi

# Категории строятся только после формирования общего списка живых URL.
grep -iE 'auth|login|token|oauth|openid|swagger|openapi|redoc|api-docs|docs|internal|debug|actuator' "$ACTIVE_HITS" \
  | sort -u > "$PRIORITY_HITS" || true
grep -iE 'auth|login|token|oauth|openid' "$ACTIVE_HITS" \
  | sort -u > "$AUTH_HITS" || true
grep -iE 'swagger|openapi|redoc|api-docs|docs' "$ACTIVE_HITS" \
  | sort -u > "$API_DOC_HITS" || true
grep -iE 'internal|debug|actuator' "$ACTIVE_HITS" \
  | sort -u > "$INTERNAL_HITS" || true

run_httpx_details() {
  local input="$1"
  local output="$2"
  [[ -s "$input" ]] || { : > "$output"; return 0; }
  "$HTTPX_BIN" \
    -l "$input" \
    -silent \
    -mc "$HTTPX_CODES" \
    -title \
    -content-length \
    -tech-detect \
    -t "$THREADS" \
    -o "$output" \
    2>> "$LOG_DIR/httpx_details.stderr.log" || true
}

run_httpx_details "$AUTH_HITS" "$CAND_DIR/auth_details.txt"
run_httpx_details "$API_DOC_HITS" "$CAND_DIR/api_docs_details.txt"
run_httpx_details "$INTERNAL_HITS" "$CAND_DIR/internal_details.txt"

log "Активных URL после httpx: $(wc -l < "$ACTIVE_HITS" | tr -d ' ')"

log "5/6: Скачивание открытых Swagger/OpenAPI-спецификаций..."
if [[ "$DOWNLOAD_SPECS" -eq 1 && -s "$API_DOC_HITS" ]]; then
  curl_tls=()
  [[ "$INSECURE" -eq 1 ]] && curl_tls=(-k)
  downloaded=0

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    [[ "$url" =~ (swagger\.(json|ya?ml)|openapi\.(json|ya?ml)|/v[0-9]+/api-docs|/api-docs)(/|$|\?) ]] || continue
    (( downloaded >= 50 )) && { warn "Достигнут лимит 50 спецификаций."; break; }

    hash="$(printf '%s' "$url" | sha256sum | awk '{print substr($1,1,16)}')"
    name="$(safe_filename "${url#*://}")"
    name="${name:0:120}"
    [[ -n "$name" ]] || name="spec"

    if [[ "$url" =~ ya?ml ]]; then
      ext="yaml"
    else
      ext="json"
    fi

    if "$CURL_BIN" "${curl_tls[@]}" -fsSL \
      --connect-timeout 5 \
      --max-time 20 \
      -H 'Accept: application/json, application/yaml, text/yaml, */*' \
      -D "$SPECS_DIR/${name}_${hash}.headers.txt" \
      "$url" \
      -o "$SPECS_DIR/${name}_${hash}.${ext}"; then
      printf '%s\t%s\n' "$url" "$SPECS_DIR/${name}_${hash}.${ext}" >> "$SPECS_DIR/downloaded.tsv"
      ((downloaded += 1))
    else
      rm -f "$SPECS_DIR/${name}_${hash}.headers.txt" "$SPECS_DIR/${name}_${hash}.${ext}"
    fi
    sleep 0.2
  done < "$API_DOC_HITS"
else
  downloaded=0
fi

log "6/6: Формирование сводки..."
{
  printf 'API recon summary\n'
  printf '=================\n'
  printf 'Domain: %s\n' "$DOMAIN"
  printf 'Started/finished: %s\n' "$(date --iso-8601=seconds)"
  printf 'Output directory: %s\n' "$OUTPUT_DIR"
  printf 'Hosts actively checked: %s\n' "$(wc -l < "$HOSTS_FILE" | tr -d ' ')"
  printf 'Historical URLs: %s\n' "$(wc -l < "$ALL_URLS" | tr -d ' ')"
  printf 'Historical API candidates: %s\n' "$(wc -l < "$API_CANDIDATES" | tr -d ' ')"
  printf 'Unique ffuf hits: %s\n' "$(wc -l < "$FFUF_HITS" | tr -d ' ')"
  printf 'All candidates (historical + ffuf): %s\n' "$(wc -l < "$ALL_CANDIDATES" | tr -d ' ')"
  printf 'Active httpx hits: %s\n' "$(wc -l < "$ACTIVE_HITS" | tr -d ' ')"
  printf 'Auth/login/token candidates: %s\n' "$(wc -l < "$AUTH_HITS" | tr -d ' ')"
  printf 'Swagger/OpenAPI/docs candidates: %s\n' "$(wc -l < "$API_DOC_HITS" | tr -d ' ')"
  printf 'Internal/debug candidates: %s\n' "$(wc -l < "$INTERNAL_HITS" | tr -d ' ')"
  printf 'Downloaded specifications: %s\n' "${downloaded:-0}"
  printf '\nImportant files:\n'
  printf '  %s\n' "$ALL_URLS"
  printf '  %s\n' "$API_CANDIDATES"
  printf '  %s\n' "$ALL_CANDIDATES"
  printf '  %s\n' "$HTTPX_JSON"
  printf '  %s\n' "$ACTIVE_HITS"
  printf '  %s\n' "$PRIORITY_HITS"
  printf '  %s\n' "$CAND_DIR/api_docs_details.txt"
} > "$SUMMARY"

log "Готово. Сводка: $SUMMARY"
log "Скрипт завершает работу на этапе разведки и получения публичных спецификаций."
