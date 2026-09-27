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
DEBUG=0
PASSIVE_TIMEOUT=120

usage() {
  cat <<EOF
Использование:
  $SCRIPT_NAME --authorized -d example.com [параметры]

Обязательные параметры:
  -d, --domain DOMAIN          Корневой домен, например example.com
  --authorized                Подтверждение разрешения на тестирование

Дополнительные параметры:
  -s, --subdomains FILE       Дополнительный файл с субдоменами
  -o, --output DIR            Каталог результатов
  -t, --threads N             Потоки ffuf/httpx, по умолчанию 20, максимум 50
  --passive-timeout N         Таймаут пассивных инструментов, по умолчанию 120 сек
  --insecure                  Не проверять TLS-сертификаты
  --no-download-specs         Не скачивать Swagger/OpenAPI
  --install-tools             Установить необходимые инструменты
  -log, --debug               Подробный режим отладки
  -h, --help                  Справка

Важно:
  Рядом со скриптом должен находиться файл wordlist.txt.

Примеры:
  chmod +x $SCRIPT_NAME
  ./$SCRIPT_NAME --authorized -d example.com
  ./$SCRIPT_NAME --authorized -d example.com --debug
  ./$SCRIPT_NAME --authorized -d example.com -s subdomains.txt
EOF
}

log()   { printf '[+] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*" >&2; }
die()   { printf '[-] %s\n' "$*" >&2; exit 1; }
debug() { [[ "$DEBUG" -eq 1 ]] && printf '[DEBUG] %s\n' "$*" >&2 || true; }

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
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's#[^a-z0-9._-]+#_#g; s#^_+|_+$##g'
}

resolve_tool() {
  local name="$1"
  local candidate

  for candidate in \
    "$HOME/go/bin/$name" \
    "/usr/local/bin/$name" \
    "/usr/bin/$name"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  command -v "$name" 2>/dev/null || return 1
}

install_tools() {
  log "Установка системных зависимостей..."

  command -v sudo >/dev/null 2>&1 ||
    die "Для --install-tools необходим sudo."

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

  log "Установка subfinder..."
  go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
}

run_with_timeout() {
  local label="$1"
  local outfile="$2"
  local errfile="$3"
  shift 3

  : > "$outfile"
  : > "$errfile"

  debug "$label: запуск: $*"
  debug "$label: таймаут ${PASSIVE_TIMEOUT}s"

  local start now elapsed pid
  start="$(date +%s)"

  timeout --preserve-status "${PASSIVE_TIMEOUT}s" "$@" \
    > "$outfile" 2> "$errfile" &
  pid=$!

  if [[ "$DEBUG" -eq 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      sleep 5
      now="$(date +%s)"
      elapsed=$((now - start))
      debug "$label: выполняется ${elapsed}s; строк: $(wc -l < "$outfile" 2>/dev/null | tr -d ' ')"
    done
  fi

  local rc=0
  wait "$pid" || rc=$?

  elapsed=$(($(date +%s) - start))

  if [[ "$rc" -eq 124 || "$rc" -eq 143 ]]; then
    warn "$label: превышен таймаут ${PASSIVE_TIMEOUT}s."
  elif [[ "$rc" -ne 0 ]]; then
    warn "$label: завершился с кодом $rc."
  else
    debug "$label: завершён за ${elapsed}s."
  fi

  if [[ ! -s "$outfile" ]]; then
    warn "$label: получено 0 строк."
    if [[ -s "$errfile" ]]; then
      warn "$label: последние сообщения stderr:"
      tail -n 10 "$errfile" >&2 || true
    fi
  else
    debug "$label: получено $(wc -l < "$outfile" | tr -d ' ') строк."
  fi

  return 0
}

while (($#)); do
  case "$1" in
    -d|--domain)
      [[ $# -ge 2 ]] || die "После $1 нужен домен."
      DOMAIN="$2"
      shift 2
      ;;
    -s|--subdomains)
      [[ $# -ge 2 ]] || die "После $1 нужен файл."
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
    --passive-timeout)
      [[ $# -ge 2 ]] || die "После $1 нужно число секунд."
      PASSIVE_TIMEOUT="$2"
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
    -log|--debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Неизвестный параметр: $1"
      ;;
  esac
done

[[ "$AUTHORIZED" -eq 1 ]] ||
  die "Добавьте --authorized только при наличии разрешения владельца системы."

[[ -n "$DOMAIN" ]] ||
  die "Не указан домен. Используйте -d example.com."

DOMAIN="$(cleanup_domain "$DOMAIN")"
valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"

[[ "$THREADS" =~ ^[0-9]+$ ]] ||
  die "--threads должен быть целым числом."
(( THREADS >= 1 && THREADS <= 50 )) ||
  die "--threads должен быть от 1 до 50."

[[ "$PASSIVE_TIMEOUT" =~ ^[0-9]+$ ]] ||
  die "--passive-timeout должен быть числом."

if [[ -n "$SUBDOMAINS_FILE" && ! -r "$SUBDOMAINS_FILE" ]]; then
  die "Не удаётся прочитать файл субдоменов: $SUBDOMAINS_FILE"
fi

if [[ "$INSTALL_TOOLS" -eq 1 ]]; then
  install_tools
fi

GAU_BIN="$(resolve_tool gau || true)"
WAYBACK_BIN="$(resolve_tool waybackurls || true)"
SUBFINDER_BIN="$(resolve_tool subfinder || true)"
FFUF_BIN="$(resolve_tool ffuf || true)"
HTTPX_BIN="$(resolve_tool httpx || true)"
JQ_BIN="$(resolve_tool jq || true)"
CURL_BIN="$(resolve_tool curl || true)"

[[ -n "$GAU_BIN" ]] || die "Не найден gau."
[[ -n "$WAYBACK_BIN" ]] || die "Не найден waybackurls."
[[ -n "$SUBFINDER_BIN" ]] || die "Не найден subfinder."
[[ -n "$FFUF_BIN" ]] || die "Не найден ffuf."
[[ -n "$HTTPX_BIN" ]] || die "Не найден ProjectDiscovery httpx."
[[ -n "$JQ_BIN" ]] || die "Не найден jq."
[[ -n "$CURL_BIN" ]] || die "Не найден curl."

HTTPX_HELP="$("$HTTPX_BIN" -h 2>&1 || true)"
if ! grep -iE 'projectdiscovery|http toolkit|status-code|tech-detect' \
  <<< "$HTTPX_HELP" >/dev/null; then

  HTTPX_VERSION="$("$HTTPX_BIN" -version 2>&1 || true)"

  if ! grep -iE 'httpx|projectdiscovery' \
    <<< "$HTTPX_VERSION" >/dev/null; then
    die "Команда '$HTTPX_BIN' не похожа на ProjectDiscovery httpx."
  fi
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="api_recon_${DOMAIN}_${TIMESTAMP}"
fi

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

HIST_DIR="$OUTPUT_DIR/historical"
SUB_DIR="$OUTPUT_DIR/subdomains"
FFUF_DIR="$OUTPUT_DIR/ffuf"
CAND_DIR="$OUTPUT_DIR/candidates"
SPECS_DIR="$OUTPUT_DIR/specs"
BASELINE_DIR="$OUTPUT_DIR/baselines"
LOG_DIR="$OUTPUT_DIR/logs"

mkdir -p \
  "$HIST_DIR" \
  "$SUB_DIR" \
  "$FFUF_DIR" \
  "$CAND_DIR" \
  "$SPECS_DIR" \
  "$BASELINE_DIR" \
  "$LOG_DIR"

RUN_LOG="$LOG_DIR/run.log"
touch "$RUN_LOG"

# Сохраняем весь вывод в run.log и одновременно показываем его на экране.
exec > >(tee -a "$RUN_LOG") 2> >(tee -a "$RUN_LOG" >&2)

GAU_FILE="$HIST_DIR/gau.txt"
WAYBACK_FILE="$HIST_DIR/waybackurls.txt"
ALL_URLS="$HIST_DIR/all_urls.txt"
INTERESTING_HIST="$HIST_DIR/interesting_urls.txt"

SUBFINDER_FILE="$SUB_DIR/subfinder.txt"
GAU_SUBDOMAINS="$SUB_DIR/gau_subdomains.txt"
USER_SUBDOMAINS="$SUB_DIR/user_subdomains.txt"
ALL_SUBDOMAINS="$SUB_DIR/all_subdomains.txt"
LIVE_HOSTS_JSON="$SUB_DIR/live_hosts.jsonl"
LIVE_HOSTS_PRE="$SUB_DIR/live_hosts_pre_placeholder_filter.txt"
LIVE_HOSTS="$SUB_DIR/live_hosts.txt"
PLACEHOLDER_SUBDOMAINS="$SUB_DIR/placeholder_subdomains.txt"
WILDCARD_BASELINE="$BASELINE_DIR/wildcard_subdomain.tsv"

HOSTS_FILE="$OUTPUT_DIR/hosts_in_scope.txt"

WORDLIST="$OUTPUT_DIR/wordlist.txt"
WORDLIST_SOURCE="$(cd "$(dirname "$0")" && pwd)/wordlist.txt"

FFUF_RAW="$CAND_DIR/ffuf_hits_raw.txt"
FFUF_HITS="$CAND_DIR/ffuf_hits.txt"
ALL_CANDIDATES="$CAND_DIR/all_candidates.txt"
HTTPX_JSON="$CAND_DIR/httpx_results.jsonl"

ACTIVE_HITS_PRE="$CAND_DIR/active_hits_pre_soft404.txt"
ACTIVE_HITS="$CAND_DIR/active_hits.txt"
SOFT404_REJECTED="$CAND_DIR/soft404_rejected.txt"
PRIORITY_HITS="$CAND_DIR/priority_hits.txt"
AUTH_HITS="$CAND_DIR/auth_login_token.txt"
API_DOC_HITS="$CAND_DIR/swagger_openapi_docs.txt"
MAIL_HITS="$CAND_DIR/mail_webmail.txt"
ADMIN_HITS="$CAND_DIR/admin_panels.txt"
INTERNAL_HITS="$CAND_DIR/internal_debug.txt"
FILES_HITS="$CAND_DIR/files_backups.txt"

SUMMARY="$OUTPUT_DIR/summary.txt"

[[ -r "$WORDLIST_SOURCE" ]] ||
  die "Не найден файл словаря: $WORDLIST_SOURCE"

cp "$WORDLIST_SOURCE" "$WORDLIST"

log "Область: $DOMAIN"
log "Каталог результатов: $OUTPUT_DIR"
log "Словарь: $WORDLIST_SOURCE ($(wc -l < "$WORDLIST" | tr -d ' ') строк)"
log "Полный лог: $RUN_LOG"

if [[ "$DEBUG" -eq 1 ]]; then
  debug "Используемые бинарники:"
  debug "gau: $GAU_BIN"
  debug "waybackurls: $WAYBACK_BIN"
  debug "subfinder: $SUBFINDER_BIN"
  debug "ffuf: $FFUF_BIN"
  debug "httpx: $HTTPX_BIN"
  debug "jq: $JQ_BIN"
  debug "curl: $CURL_BIN"

  debug "DNS:"
  getent ahosts "$DOMAIN" 2>&1 | head -n 20 >&2 || true
fi

###############################################################################
# 1/8 SUBDOMAIN DISCOVERY
###############################################################################

log "1/8: Поиск субдоменов через subfinder..."

run_with_timeout \
  "subfinder" \
  "$SUBFINDER_FILE" \
  "$LOG_DIR/subfinder.stderr.log" \
  "$SUBFINDER_BIN" \
    -d "$DOMAIN" \
    -silent

###############################################################################
# 2/8 GAU
###############################################################################

log "2/8: Сбор исторических URL через gau..."

# CommonCrawl намеренно исключён: в ряде сетей он часто зависает.
run_with_timeout \
  "gau" \
  "$GAU_FILE" \
  "$LOG_DIR/gau.stderr.log" \
  "$GAU_BIN" \
    --providers wayback,otx,urlscan \
    --timeout 15 \
    --retries 2 \
    --subs \
    "$DOMAIN"

if [[ -s "$GAU_FILE" ]]; then
  grep -E '^https?://' "$GAU_FILE" |
    sed '/^[[:space:]]*$/d' |
    sort -u > "$GAU_FILE.tmp" || true

  mv "$GAU_FILE.tmp" "$GAU_FILE"
fi

###############################################################################
# 3/8 WAYBACKURLS
###############################################################################

log "3/8: Сбор URL через waybackurls..."

: > "$WAYBACK_FILE"

if [[ "$DEBUG" -eq 1 ]]; then
  debug "waybackurls: домен $DOMAIN, timeout ${PASSIVE_TIMEOUT}s"
fi

set +e
printf '%s\n' "$DOMAIN" |
  timeout "${PASSIVE_TIMEOUT}s" "$WAYBACK_BIN" \
  > "$WAYBACK_FILE" \
  2> "$LOG_DIR/waybackurls.stderr.log"
WAYBACK_RC=$?
set -e

if [[ "$WAYBACK_RC" -eq 124 || "$WAYBACK_RC" -eq 143 ]]; then
  warn "waybackurls: превышен таймаут ${PASSIVE_TIMEOUT}s; продолжаю работу."
elif [[ "$WAYBACK_RC" -ne 0 ]]; then
  warn "waybackurls завершился с кодом $WAYBACK_RC."
fi

# Если waybackurls ничего не вернул или был остановлен timeout,
# пробуем напрямую Wayback CDX API.
if [[ ! -s "$WAYBACK_FILE" ]]; then
  warn "waybackurls вернул 0 URL. Пробую прямой Wayback CDX API..."

  CDX_TMP="$HIST_DIR/wayback_cdx.tmp"

  set +e
  "$CURL_BIN" \
    -fsSL \
    --connect-timeout 10 \
    --max-time 60 \
    --get \
    --data-urlencode "url=*.$DOMAIN/*" \
    --data-urlencode "output=txt" \
    --data-urlencode "fl=original" \
    --data-urlencode "collapse=urlkey" \
    "https://web.archive.org/cdx/search/cdx" \
    > "$CDX_TMP" \
    2> "$LOG_DIR/wayback_cdx.stderr.log"
  CDX_RC=$?
  set -e

  if [[ "$CDX_RC" -eq 0 && -s "$CDX_TMP" ]]; then
    grep -E '^https?://' "$CDX_TMP" | sort -u > "$WAYBACK_FILE" || true
    log "Wayback CDX вернул $(wc -l < "$WAYBACK_FILE" | tr -d ' ') URL."
  else
    warn "Wayback CDX также не вернул URL."
  fi

  rm -f "$CDX_TMP"
fi

if [[ -s "$WAYBACK_FILE" ]]; then
  sort -u -o "$WAYBACK_FILE" "$WAYBACK_FILE"
fi


# Создаёт сигнатуру default-vhost / wildcard-заглушки на случайных
# несуществующих субдоменах. Если два случайных имени возвращают один и тот же
# ответ, этот ответ считаем baseline для "фальшивых" субдоменов.
detect_wildcard_subdomain_baseline() {
  local rnd1 rnd2 host1 host2
  local scheme1 scheme2 mode1 mode2
  local body1 body2 meta1 meta2
  local code1 code2 size1 size2 hash1 hash2

  rnd1="__recon_wild_${RANDOM}_${RANDOM}_a"
  rnd2="__recon_wild_${RANDOM}_${RANDOM}_b"
  host1="${rnd1}.${DOMAIN}"
  host2="${rnd2}.${DOMAIN}"

  : > "$WILDCARD_BASELINE"

  # Сначала проверяем, разрешаются ли случайные имена вообще.
  if ! getent ahosts "$host1" >/dev/null 2>&1; then
    debug "Wildcard DNS не обнаружен: $host1 не разрешается."
    return 1
  fi

  if ! getent ahosts "$host2" >/dev/null 2>&1; then
    debug "Wildcard DNS не подтверждён вторым случайным именем."
    return 1
  fi

  scheme1="$(choose_scheme "$host1")"
  scheme2="$(choose_scheme "$host2")"

  mode1="${scheme1##*|}"
  mode2="${scheme2##*|}"
  scheme1="${scheme1%%|*}"
  scheme2="${scheme2%%|*}"

  # Для baseline оба случайных имени должны вести по одной схеме.
  [[ "$scheme1" == "$scheme2" ]] || {
    debug "Wildcard baseline: схемы случайных хостов различаются."
    return 1
  }

  local curl_tls1=()
  local curl_tls2=()

  [[ "$INSECURE" -eq 1 || "$mode1" == "insecure" ]] && curl_tls1=(-k)
  [[ "$INSECURE" -eq 1 || "$mode2" == "insecure" ]] && curl_tls2=(-k)

  body1="$BASELINE_DIR/wildcard_subdomain_1.body"
  body2="$BASELINE_DIR/wildcard_subdomain_2.body"

  meta1="$("$CURL_BIN" "${curl_tls1[@]}" -L -sS \
    --connect-timeout 5 --max-time 12 \
    -o "$body1" \
    -w '%{http_code}\t%{size_download}' \
    "$scheme1://$host1/" 2>> "$LOG_DIR/wildcard_subdomain.stderr.log" || true)"

  meta2="$("$CURL_BIN" "${curl_tls2[@]}" -L -sS \
    --connect-timeout 5 --max-time 12 \
    -o "$body2" \
    -w '%{http_code}\t%{size_download}' \
    "$scheme2://$host2/" 2>> "$LOG_DIR/wildcard_subdomain.stderr.log" || true)"

  code1="${meta1%%$'\t'*}"
  size1="${meta1##*$'\t'}"
  code2="${meta2%%$'\t'*}"
  size2="${meta2##*$'\t'}"

  [[ "$code1" =~ ^[0-9]{3}$ && "$code2" =~ ^[0-9]{3}$ ]] || return 1
  [[ -s "$body1" && -s "$body2" ]] || return 1

  hash1="$(sha256sum "$body1" | awk '{print $1}')"
  hash2="$(sha256sum "$body2" | awk '{print $1}')"

  if [[ "$code1" == "$code2" && "$size1" == "$size2" && "$hash1" == "$hash2" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$scheme1" "$code1" "$size1" "$hash1" > "$WILDCARD_BASELINE"
    log "Wildcard/default-vhost обнаружен: случайные субдомены возвращают одинаковую страницу HTTP $code1, ${size1} B."
    return 0
  fi

  debug "Случайные субдомены разрешаются, но одинаковой заглушки не обнаружено."
  return 1
}

# Сравнивает корневую страницу найденного субдомена с wildcard/default-vhost baseline.
is_placeholder_subdomain() {
  local host="$1"

  [[ -s "$WILDCARD_BASELINE" ]] || return 1

  local expected_scheme expected_code expected_size expected_hash
  IFS=$'\t' read -r expected_scheme expected_code expected_size expected_hash < "$WILDCARD_BASELINE"

  local scheme_info scheme tls_mode
  scheme_info="$(choose_scheme "$host")"
  scheme="${scheme_info%%|*}"
  tls_mode="${scheme_info##*|}"

  local curl_tls=()
  [[ "$INSECURE" -eq 1 || "$tls_mode" == "insecure" ]] && curl_tls=(-k)

  local tmp_body meta code size hash
  tmp_body="$BASELINE_DIR/subdomain_$(safe_filename "$host").body"

  meta="$("$CURL_BIN" "${curl_tls[@]}" -L -sS \
    --connect-timeout 5 --max-time 12 \
    -o "$tmp_body" \
    -w '%{http_code}\t%{size_download}' \
    "$scheme://$host/" 2>> "$LOG_DIR/wildcard_subdomain.stderr.log" || true)"

  code="${meta%%$'\t'*}"
  size="${meta##*$'\t'}"

  if [[ -s "$tmp_body" ]]; then
    hash="$(sha256sum "$tmp_body" | awk '{print $1}')"
  else
    hash=""
  fi

  rm -f "$tmp_body"

  if [[ "$scheme" == "$expected_scheme" &&
        "$code" == "$expected_code" &&
        "$size" == "$expected_size" &&
        "$hash" == "$expected_hash" ]]; then
    return 0
  fi

  return 1
}

###############################################################################
# SUBDOMAIN MERGE
###############################################################################

log "4/8: Объединение и проверка найденных субдоменов..."

: > "$GAU_SUBDOMAINS"
: > "$USER_SUBDOMAINS"

# Извлекаем хосты из URL gau.
if [[ -s "$GAU_FILE" ]]; then
  sed -E 's#^https?://##; s#/.*$##; s/:.*$//' "$GAU_FILE" |
    tr '[:upper:]' '[:lower:]' |
    sort -u |
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      host_in_scope "$host" && printf '%s\n' "$host"
    done > "$GAU_SUBDOMAINS"
fi

# Пользовательский список -s сохраняется и тоже объединяется.
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
  done < "$SUBDOMAINS_FILE" |
    sort -u > "$USER_SUBDOMAINS"
fi

{
  printf '%s\n' "$DOMAIN"
  cat "$SUBFINDER_FILE" 2>/dev/null || true
  cat "$GAU_SUBDOMAINS" 2>/dev/null || true
  cat "$USER_SUBDOMAINS" 2>/dev/null || true
} |
  sed '/^[[:space:]]*$/d' |
  tr '[:upper:]' '[:lower:]' |
  sort -u |
  while IFS= read -r host; do
    host_in_scope "$host" && printf '%s\n' "$host"
  done > "$ALL_SUBDOMAINS"

cp "$ALL_SUBDOMAINS" "$HOSTS_FILE"

log "Найдено уникальных хостов в области: $(wc -l < "$ALL_SUBDOMAINS" | tr -d ' ')"

: > "$LIVE_HOSTS_JSON"
: > "$LIVE_HOSTS_PRE"
: > "$LIVE_HOSTS"
: > "$PLACEHOLDER_SUBDOMAINS"

if [[ -s "$ALL_SUBDOMAINS" ]]; then
  "$HTTPX_BIN" \
    -l "$ALL_SUBDOMAINS" \
    -silent \
    -json \
    -follow-redirects \
    -title \
    -tech-detect \
    -t "$THREADS" \
    -o "$LIVE_HOSTS_JSON" \
    2> "$LOG_DIR/httpx_hosts.stderr.log" || true

  "$JQ_BIN" -r '
    select(.failed == false)
    | (.url // .input // empty)
  ' "$LIVE_HOSTS_JSON" 2>/dev/null |
    sed '/^[[:space:]]*$/d' |
    sort -u > "$LIVE_HOSTS_PRE" || true

  # Проверяем wildcard/default-vhost только после того, как уже получили список
  # отвечающих хостов.
  detect_wildcard_subdomain_baseline || true

  while IFS= read -r live_url; do
    [[ -n "$live_url" ]] || continue

    rest="${live_url#*://}"
    host="${rest%%/*}"
    host="${host%%:*}"

    # Корневой домен никогда не выбрасываем как "placeholder subdomain".
    if [[ "$host" == "$DOMAIN" ]]; then
      printf '%s\n' "$live_url" >> "$LIVE_HOSTS"
      continue
    fi

    if is_placeholder_subdomain "$host"; then
      printf '%s\n' "$host" >> "$PLACEHOLDER_SUBDOMAINS"
      debug "Исключён placeholder-субдомен: $host"
    else
      printf '%s\n' "$live_url" >> "$LIVE_HOSTS"
    fi
  done < "$LIVE_HOSTS_PRE"

  sort -u -o "$LIVE_HOSTS" "$LIVE_HOSTS"
  sort -u -o "$PLACEHOLDER_SUBDOMAINS" "$PLACEHOLDER_SUBDOMAINS"
fi

log "Отвечающих web-хостов до фильтра заглушек: $(wc -l < "$LIVE_HOSTS_PRE" | tr -d ' ')"
log "Исключено placeholder-субдоменов: $(wc -l < "$PLACEHOLDER_SUBDOMAINS" | tr -d ' ')"
log "Реальных web-хостов после фильтра: $(wc -l < "$LIVE_HOSTS" | tr -d ' ')"

###############################################################################
# HISTORICAL MERGE
###############################################################################

cat "$GAU_FILE" "$WAYBACK_FILE" 2>/dev/null |
  grep -E '^https?://' |
  sed '/^[[:space:]]*$/d' |
  sort -u > "$ALL_URLS" || true

grep -iE \
'/api(/|$)|/v[0-9]+(/|$)|/auth(/|$)|/token|/login|/signin|/oauth|/openid|/swagger|/openapi|/api-docs|/docs|/redoc|/admin|/administrator|/dashboard|/panel|/portal|/mail|/webmail|/roundcube|/owa|/autodiscover|/phpmyadmin|/adminer|/graphql|/graphiql|/server-status|/server-info|/metrics|/monitor|/grafana|/actuator|/health|/status|/backup|/backups|/debug|/internal' \
  "$ALL_URLS" |
  sort -u > "$INTERESTING_HIST" || true

log "Исторических URL: $(wc -l < "$ALL_URLS" | tr -d ' ')"
log "Интересных исторических URL: $(wc -l < "$INTERESTING_HIST" | tr -d ' ')"

###############################################################################
# 5/8 FFUF
###############################################################################

choose_scheme() {
  local host="$1"

  if "$CURL_BIN" \
      -sS \
      -o /dev/null \
      --connect-timeout 5 \
      --max-time 8 \
      "https://$host/"; then
    printf 'https|verify'
    return
  fi

  # Если HTTPS работает только при отключённой проверке сертификата,
  # всё равно используем HTTPS, а не переключаемся ошибочно на HTTP.
  if "$CURL_BIN" \
      -k \
      -sS \
      -o /dev/null \
      --connect-timeout 5 \
      --max-time 8 \
      "https://$host/"; then
    printf 'https|insecure'
    return
  fi

  if "$CURL_BIN" \
      -sS \
      -o /dev/null \
      --connect-timeout 5 \
      --max-time 8 \
      "http://$host/"; then
    printf 'http|verify'
    return
  fi

  printf 'https|unreachable'
}


# Проверяет, отдаёт ли сайт одинаковую "страницу не найдена" с успешным HTTP-кодом.
# Высокоуверенный soft-404 определяется только если два случайных несуществующих
# пути имеют одинаковый HTTP-код, размер и SHA-256 тела.
detect_soft404_baseline() {
  local host="$1"
  local base_path="$2"
  local label="$3"
  local scheme="$4"
  local tls_mode="$5"

  local host_name token1 token2 url1 url2
  local body1 body2 meta1 meta2
  local code1 code2 size1 size2 hash1 hash2
  local curl_tls=()

  host_name="$(safe_filename "$host")"
  token1="__recon_missing_${RANDOM}_${RANDOM}_a__"
  token2="__recon_missing_${RANDOM}_${RANDOM}_b__"

  url1="$scheme://$host$base_path/$token1"
  url2="$scheme://$host$base_path/$token2"

  body1="$BASELINE_DIR/${host_name}_${label}_1.body"
  body2="$BASELINE_DIR/${host_name}_${label}_2.body"

  if [[ "$INSECURE" -eq 1 || "$tls_mode" == "insecure" ]]; then
    curl_tls=(-k)
  fi

  meta1="$("$CURL_BIN" "${curl_tls[@]}" -L -sS \
    --connect-timeout 5 --max-time 12 \
    -o "$body1" \
    -w '%{http_code}\t%{size_download}' \
    "$url1" 2>> "$LOG_DIR/soft404.stderr.log" || true)"

  meta2="$("$CURL_BIN" "${curl_tls[@]}" -L -sS \
    --connect-timeout 5 --max-time 12 \
    -o "$body2" \
    -w '%{http_code}\t%{size_download}' \
    "$url2" 2>> "$LOG_DIR/soft404.stderr.log" || true)"

  code1="${meta1%%$'\t'*}"
  size1="${meta1##*$'\t'}"
  code2="${meta2%%$'\t'*}"
  size2="${meta2##*$'\t'}"

  [[ "$code1" =~ ^[0-9]{3}$ ]] || return 1
  [[ "$code2" =~ ^[0-9]{3}$ ]] || return 1
  [[ -s "$body1" && -s "$body2" ]] || return 1

  hash1="$(sha256sum "$body1" | awk '{print $1}')"
  hash2="$(sha256sum "$body2" | awk '{print $1}')"

  if [[ "$code1" == "$code2" && "$size1" == "$size2" && "$hash1" == "$hash2" ]]; then
    printf '%s\t%s\t%s\n' "$code1" "$size1" "$hash1" \
      > "$BASELINE_DIR/${host_name}_${label}.tsv"

    log "soft-404: $host$base_path -> HTTP $code1, ${size1} B; одинаковая заглушка будет исключаться."
    return 0
  fi

  rm -f "$BASELINE_DIR/${host_name}_${label}.tsv"
  debug "soft-404: стабильная заглушка для $host$base_path не обнаружена."
  return 1
}

# После httpx перепроверяет кандидаты против сохранённых soft-404 baseline.
# Это дополнительно убирает исторические URL, которые могли вернуть ту же
# custom-404 страницу с кодом 200.
filter_soft404_hits() {
  local input="$1"
  local output="$2"
  local rejected="$3"

  : > "$output"
  : > "$rejected"

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue

    local rest host path label host_name sigfile
    local expected_code expected_size expected_hash
    local tmp_body meta code size hash
    local curl_tls=()

    rest="${url#*://}"
    host="${rest%%/*}"
    host="${host%%:*}"
    path="/${rest#*/}"
    [[ "$rest" == "$host" ]] && path="/"

    if [[ "$path" == /api/* || "$path" == "/api" ]]; then
      label="api"
    else
      label="root"
    fi

    host_name="$(safe_filename "$host")"
    sigfile="$BASELINE_DIR/${host_name}_${label}.tsv"

    if [[ ! -s "$sigfile" ]]; then
      printf '%s\n' "$url" >> "$output"
      continue
    fi

    IFS=$'\t' read -r expected_code expected_size expected_hash < "$sigfile"

    tmp_body="$BASELINE_DIR/check_$(printf '%s' "$url" | sha256sum | awk '{print substr($1,1,16)}').body"

    if [[ "$INSECURE" -eq 1 ]]; then
      curl_tls=(-k)
    fi

    meta="$("$CURL_BIN" "${curl_tls[@]}" -L -sS \
      --connect-timeout 5 --max-time 12 \
      -o "$tmp_body" \
      -w '%{http_code}\t%{size_download}' \
      "$url" 2>> "$LOG_DIR/soft404.stderr.log" || true)"

    code="${meta%%$'\t'*}"
    size="${meta##*$'\t'}"

    if [[ -s "$tmp_body" ]]; then
      hash="$(sha256sum "$tmp_body" | awk '{print $1}')"
    else
      hash=""
    fi

    rm -f "$tmp_body"

    if [[ "$code" == "$expected_code" && "$size" == "$expected_size" && "$hash" == "$expected_hash" ]]; then
      printf '%s\n' "$url" >> "$rejected"
      debug "soft-404 исключён: $url"
    else
      printf '%s\n' "$url" >> "$output"
    fi
  done < "$input"

  sort -u -o "$output" "$output"
  sort -u -o "$rejected" "$rejected"
}

run_ffuf() {
  local host="$1"
  local base_path="$2"
  local label="$3"
  local scheme="$4"
  local tls_mode="$5"

  local host_name
  local ffuf_tls=()
  local soft404_filter=()

  host_name="$(safe_filename "$host")"

  if [[ "$INSECURE" -eq 1 || "$tls_mode" == "insecure" ]]; then
    ffuf_tls=(-k)
  fi

  if detect_soft404_baseline "$host" "$base_path" "$label" "$scheme" "$tls_mode"; then
    local baseline_file baseline_code baseline_size baseline_hash
    baseline_file="$BASELINE_DIR/${host_name}_${label}.tsv"
    IFS=$'\t' read -r baseline_code baseline_size baseline_hash < "$baseline_file"

    # Фильтруем по размеру, а не по HTTP-коду: настоящий endpoint тоже может
    # возвращать 200, поэтому -fc 200 дал бы ложные отрицания.
    soft404_filter=(-fs "$baseline_size")
  fi

  log "ffuf: $scheme://$host$base_path/FUZZ"

  "$FFUF_BIN" \
    -u "$scheme://$host$base_path/FUZZ" \
    -w "$WORDLIST" \
    -mc "$FFUF_CODES" \
    -ac \
    "${soft404_filter[@]}" \
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

log "5/8: Активная проверка путей через ffuf..."

SCAN_HOSTS="$SUB_DIR/scan_hosts.txt"
: > "$SCAN_HOSTS"

# live_hosts.txt хранит URL; преобразуем их обратно в hostnames.
if [[ -s "$LIVE_HOSTS" ]]; then
  sed -E 's#^https?://##; s#/.*$##; s/:.*$//' "$LIVE_HOSTS" |
    sed '/^[[:space:]]*$/d' |
    sort -u > "$SCAN_HOSTS"
fi

# Корневой домен сканируем всегда, если он не попал в список выше.
printf '%s\n' "$DOMAIN" >> "$SCAN_HOSTS"
sort -u -o "$SCAN_HOSTS" "$SCAN_HOSTS"

log "Хостов для ffuf после фильтра заглушек: $(wc -l < "$SCAN_HOSTS" | tr -d ' ')"

while IFS= read -r host; do
  [[ -n "$host" ]] || continue

  scheme_info="$(choose_scheme "$host")"
  scheme="${scheme_info%%|*}"
  tls_mode="${scheme_info##*|}"

  if [[ "$tls_mode" == "unreachable" ]]; then
    warn "$host: curl не подтвердил доступность; ffuf всё равно попробует HTTPS."
  fi

  debug "$host -> $scheme ($tls_mode)"

  run_ffuf "$host" "" "root" "$scheme" "$tls_mode"
  run_ffuf "$host" "/api" "api" "$scheme" "$tls_mode"

  sleep 0.2
done < "$SCAN_HOSTS"

: > "$FFUF_RAW"

shopt -s nullglob
for json_file in "$FFUF_DIR"/*.json; do
  [[ -s "$json_file" ]] || continue

  "$JQ_BIN" -r \
    '.results[]?.url // empty' \
    "$json_file" \
    2>/dev/null >> "$FFUF_RAW" || true
done
shopt -u nullglob

sort -u "$FFUF_RAW" > "$FFUF_HITS"

log "Найдено уникальных URL через ffuf: $(wc -l < "$FFUF_HITS" | tr -d ' ')"

###############################################################################
# 6/8 HTTPX URL VALIDATION
###############################################################################

log "6/8: Объединение кандидатов и проверка через httpx..."

{
  cat "$INTERESTING_HIST" 2>/dev/null || true
  cat "$FFUF_HITS" 2>/dev/null || true
} |
  sed '/^[[:space:]]*$/d' |
  sort -u |
  while IFS= read -r url; do
    [[ "$url" =~ ^https?:// ]] || continue

    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    host="${host,,}"

    host_in_scope "$host" && printf '%s\n' "$url"
  done > "$ALL_CANDIDATES"

log "Всего кандидатов для httpx: $(wc -l < "$ALL_CANDIDATES" | tr -d ' ')"

: > "$HTTPX_JSON"
: > "$ACTIVE_HITS_PRE"
: > "$ACTIVE_HITS"
: > "$SOFT404_REJECTED"

if [[ -s "$ALL_CANDIDATES" ]]; then
  "$HTTPX_BIN" \
    -l "$ALL_CANDIDATES" \
    -silent \
    -json \
    -follow-redirects \
    -title \
    -content-length \
    -tech-detect \
    -t "$THREADS" \
    -o "$HTTPX_JSON" \
    2> "$LOG_DIR/httpx_urls.stderr.log" || true

  "$JQ_BIN" -r --arg codes "$HTTPX_CODES" '
    ($codes | split(",") | map(tonumber)) as $allowed
    | select(.status_code as $s | $allowed | index($s))
    | (.url // .input // empty)
  ' "$HTTPX_JSON" 2>> "$LOG_DIR/httpx_urls.stderr.log" |
    sed '/^[[:space:]]*$/d' |
    sort -u > "$ACTIVE_HITS_PRE" || true

  if [[ -s "$ACTIVE_HITS_PRE" ]]; then
    filter_soft404_hits "$ACTIVE_HITS_PRE" "$ACTIVE_HITS" "$SOFT404_REJECTED"
  fi
fi

log "Ответов httpx: $(wc -l < "$HTTPX_JSON" | tr -d ' ')"
log "Кандидатов до soft-404 фильтра: $(wc -l < "$ACTIVE_HITS_PRE" | tr -d ' ')"
log "Исключено soft-404: $(wc -l < "$SOFT404_REJECTED" | tr -d ' ')"
log "Активных интересных URL: $(wc -l < "$ACTIVE_HITS" | tr -d ' ')"

###############################################################################
# CATEGORIES
###############################################################################

grep -iE \
'auth|login|signin|token|oauth|openid|swagger|openapi|redoc|api-docs|docs|internal|debug|actuator|mail|webmail|roundcube|owa|autodiscover|admin|administrator|dashboard|panel|portal|phpmyadmin|adminer|graphql|metrics|monitor|grafana|server-status|server-info|backup|health|status' \
  "$ACTIVE_HITS" |
  sort -u > "$PRIORITY_HITS" || true

grep -iE \
'auth|login|signin|token|oauth|openid|account' \
  "$ACTIVE_HITS" |
  sort -u > "$AUTH_HITS" || true

grep -iE \
'swagger|openapi|redoc|api-docs|docs' \
  "$ACTIVE_HITS" |
  sort -u > "$API_DOC_HITS" || true

grep -iE \
'mail|webmail|roundcube|roundcubemail|rainloop|squirrelmail|owa|exchange|autodiscover|autoconfig' \
  "$ACTIVE_HITS" |
  sort -u > "$MAIL_HITS" || true

grep -iE \
'admin|administrator|dashboard|panel|controlpanel|manage|manager|management|console|portal|phpmyadmin|adminer' \
  "$ACTIVE_HITS" |
  sort -u > "$ADMIN_HITS" || true

grep -iE \
'internal|debug|actuator|health|monitor|metrics|grafana|server-status|server-info|diagnostic' \
  "$ACTIVE_HITS" |
  sort -u > "$INTERNAL_HITS" || true

grep -iE \
'backup|backups|archive|archives|dump|upload|uploads|download|downloads|files' \
  "$ACTIVE_HITS" |
  sort -u > "$FILES_HITS" || true

###############################################################################
# 7/8 SWAGGER/OPENAPI DOWNLOAD
###############################################################################

log "7/8: Скачивание открытых Swagger/OpenAPI-спецификаций..."

downloaded=0

if [[ "$DOWNLOAD_SPECS" -eq 1 && -s "$API_DOC_HITS" ]]; then
  curl_tls=()

  [[ "$INSECURE" -eq 1 ]] && curl_tls=(-k)

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue

    [[ "$url" =~ (swagger\.(json|ya?ml)|openapi\.(json|ya?ml)|/v[0-9]+/api-docs|/api-docs)(/|$|\?) ]] ||
      continue

    (( downloaded >= 50 )) && {
      warn "Достигнут лимит 50 спецификаций."
      break
    }

    hash="$(printf '%s' "$url" | sha256sum | awk '{print substr($1,1,16)}')"
    name="$(safe_filename "${url#*://}")"
    name="${name:0:120}"

    [[ -n "$name" ]] || name="spec"

    if [[ "$url" =~ ya?ml ]]; then
      ext="yaml"
    else
      ext="json"
    fi

    if "$CURL_BIN" \
      "${curl_tls[@]}" \
      -fsSL \
      --connect-timeout 5 \
      --max-time 20 \
      -H 'Accept: application/json, application/yaml, text/yaml, */*' \
      -D "$SPECS_DIR/${name}_${hash}.headers.txt" \
      "$url" \
      -o "$SPECS_DIR/${name}_${hash}.${ext}"; then

      printf '%s\t%s\n' \
        "$url" \
        "$SPECS_DIR/${name}_${hash}.${ext}" \
        >> "$SPECS_DIR/downloaded.tsv"

      ((downloaded += 1))
    else
      rm -f \
        "$SPECS_DIR/${name}_${hash}.headers.txt" \
        "$SPECS_DIR/${name}_${hash}.${ext}"
    fi

    sleep 0.2
  done < "$API_DOC_HITS"
fi

###############################################################################
# 8/8 SUMMARY
###############################################################################

log "8/8: Формирование сводки..."

{
  printf 'Web/API recon summary\n'
  printf '=====================\n'
  printf 'Domain: %s\n' "$DOMAIN"
  printf 'Finished: %s\n' "$(date --iso-8601=seconds)"
  printf 'Output directory: %s\n' "$OUTPUT_DIR"

  printf '\nSubdomains\n'
  printf '----------\n'
  printf 'Subfinder: %s\n' "$(wc -l < "$SUBFINDER_FILE" | tr -d ' ')"
  printf 'From gau URLs: %s\n' "$(wc -l < "$GAU_SUBDOMAINS" | tr -d ' ')"
  printf 'User supplied: %s\n' "$(wc -l < "$USER_SUBDOMAINS" | tr -d ' ')"
  printf 'All unique hosts: %s\n' "$(wc -l < "$ALL_SUBDOMAINS" | tr -d ' ')"
  printf 'Responding web hosts before placeholder filter: %s\n' "$(wc -l < "$LIVE_HOSTS_PRE" | tr -d ' ')"
  printf 'Rejected placeholder subdomains: %s\n' "$(wc -l < "$PLACEHOLDER_SUBDOMAINS" | tr -d ' ')"
  printf 'Live web hosts after placeholder filter: %s\n' "$(wc -l < "$LIVE_HOSTS" | tr -d ' ')"

  printf '\nURLs\n'
  printf '----\n'
  printf 'Historical URLs: %s\n' "$(wc -l < "$ALL_URLS" | tr -d ' ')"
  printf 'Interesting historical URLs: %s\n' "$(wc -l < "$INTERESTING_HIST" | tr -d ' ')"
  printf 'Unique ffuf hits: %s\n' "$(wc -l < "$FFUF_HITS" | tr -d ' ')"
  printf 'All candidates: %s\n' "$(wc -l < "$ALL_CANDIDATES" | tr -d ' ')"
  printf 'Candidates before soft-404 filtering: %s\n' "$(wc -l < "$ACTIVE_HITS_PRE" | tr -d ' ')"
  printf 'Rejected soft-404 URLs: %s\n' "$(wc -l < "$SOFT404_REJECTED" | tr -d ' ')"
  printf 'Active interesting URLs: %s\n' "$(wc -l < "$ACTIVE_HITS" | tr -d ' ')"

  printf '\nCategories\n'
  printf '----------\n'
  printf 'Priority: %s\n' "$(wc -l < "$PRIORITY_HITS" | tr -d ' ')"
  printf 'Auth/login/token: %s\n' "$(wc -l < "$AUTH_HITS" | tr -d ' ')"
  printf 'Swagger/OpenAPI/docs: %s\n' "$(wc -l < "$API_DOC_HITS" | tr -d ' ')"
  printf 'Mail/webmail: %s\n' "$(wc -l < "$MAIL_HITS" | tr -d ' ')"
  printf 'Admin/panels: %s\n' "$(wc -l < "$ADMIN_HITS" | tr -d ' ')"
  printf 'Internal/debug/monitoring: %s\n' "$(wc -l < "$INTERNAL_HITS" | tr -d ' ')"
  printf 'Files/backups: %s\n' "$(wc -l < "$FILES_HITS" | tr -d ' ')"
  printf 'Downloaded specifications: %s\n' "$downloaded"

  printf '\nImportant files\n'
  printf '---------------\n'
  printf '%s\n' "$ALL_SUBDOMAINS"
  printf '%s\n' "$LIVE_HOSTS"
  printf '%s\n' "$PLACEHOLDER_SUBDOMAINS"
  printf '%s\n' "$ALL_URLS"
  printf '%s\n' "$INTERESTING_HIST"
  printf '%s\n' "$ACTIVE_HITS"
  printf '%s\n' "$SOFT404_REJECTED"
  printf '%s\n' "$PRIORITY_HITS"
  printf '%s\n' "$HTTPX_JSON"
  printf '%s\n' "$RUN_LOG"
} > "$SUMMARY"

log "Готово."
log "Сводка: $SUMMARY"
log "Все логи: $LOG_DIR"
