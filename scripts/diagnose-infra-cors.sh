#!/usr/bin/env bash
set -u

ORIGIN="${ORIGIN:-${CORS_ORIGIN:-}}"
PUBLIC_URL="${PUBLIC_URL:-${BASE_URL:-}}"
CHAT_PATH="${CHAT_PATH:-/ws/chat/info?t=$(date +%s)}"
REPORT="${REPORT:-/tmp/nexatech-cors-diagnosis-$(hostname)-$(date +%Y%m%d-%H%M%S).log}"
CURL_TIMEOUT="${CURL_TIMEOUT:-8}"
KONG_CONFIG="${KONG_CONFIG:-/opt/nexatech/kong/kong.yml}"
RUNTIME_ENV="${RUNTIME_ENV:-/opt/nexatech/runtime.env}"
ENV_DIR="${ENV_DIR:-/opt/nexatech/env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/nexatech/compose/infra.docker-compose.yml}"

SENSITIVE_RE='(PASSWORD|PASS|CLIENT_SECRET|SECRET|TOKEN|CREDENTIAL|AUTHORIZATION|PRIVATE|ACCESS_KEY|SECRET_KEY|API_KEY)'

usage() {
  cat <<'USAGE'
Usage:
  ORIGIN=https://your-frontend.vercel.app PUBLIC_URL=https://xxxx.cloudfront.net scripts/diagnose-infra-cors.sh

Environment:
  ORIGIN       Required. Browser Origin that is blocked by CORS.
  PUBLIC_URL   Optional. Public API URL, for example CloudFront URL.
  CHAT_PATH    Optional. Defaults to /ws/chat/info?t=<timestamp>.
  REPORT       Optional. Output report path under /tmp by default.

Run this on the infra EC2 host where Kong/api-gateway containers run.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "$ORIGIN" ]; then
  echo "ORIGIN is required." >&2
  echo "Example: ORIGIN=https://your-frontend.vercel.app PUBLIC_URL=https://dc6009irjdpez.cloudfront.net $0" >&2
  exit 1
fi

: >"$REPORT"

section() {
  printf '\n\n========== %s ==========\n' "$1" | tee -a "$REPORT"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

read_file() {
  local file="$1"
  if [ -r "$file" ]; then
    cat "$file"
  elif have sudo; then
    sudo -n cat "$file" 2>/dev/null || echo "permission denied: $file"
  else
    echo "permission denied: $file"
  fi
}

redact_env_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "missing: $file"
    return
  fi

  read_file "$file" | awk -F= -v re="$SENSITIVE_RE" '
    /^[[:space:]]*#/ || NF < 2 { print; next }
    toupper($1) ~ re { print $1"=<redacted>"; next }
    { print }
  '
}

curl_headers() {
  local method="$1"
  local url="$2"
  local tmp_body
  tmp_body="$(mktemp /tmp/nexatech-cors-body.XXXXXX)"

  echo "--- $method $url" | tee -a "$REPORT"
  if [ "$method" = "OPTIONS" ]; then
    curl -k -sS -m "$CURL_TIMEOUT" \
      -D - -o "$tmp_body" \
      -X OPTIONS \
      -H "Origin: $ORIGIN" \
      -H "Access-Control-Request-Method: GET" \
      -H "Access-Control-Request-Headers: authorization,content-type,x-requested-with" \
      "$url" 2>&1 | tee -a "$REPORT"
  else
    curl -k -sS -m "$CURL_TIMEOUT" \
      -D - -o "$tmp_body" \
      -X "$method" \
      -H "Origin: $ORIGIN" \
      -H "Accept: application/json, text/plain, */*" \
      "$url" 2>&1 | tee -a "$REPORT"
  fi

  if [ -s "$tmp_body" ]; then
    echo "--- body preview" | tee -a "$REPORT"
    head -c 600 "$tmp_body" | tr '\n' ' ' | tee -a "$REPORT"
    echo | tee -a "$REPORT"
  fi
  rm -f "$tmp_body"
}

cors_summary() {
  local url="$1"
  local tmp_headers
  tmp_headers="$(mktemp /tmp/nexatech-cors-headers.XXXXXX)"

  curl -k -sS -m "$CURL_TIMEOUT" \
    -D "$tmp_headers" -o /dev/null \
    -H "Origin: $ORIGIN" \
    "$url" >/dev/null 2>&1 || true

  echo "--- $url" | tee -a "$REPORT"
  awk 'BEGIN{IGNORECASE=1} /^HTTP\// || /^access-control-/ || /^vary:/ || /^server:/ || /^x-kong-/ || /^via:/ {print}' "$tmp_headers" | tee -a "$REPORT"
  if ! awk 'BEGIN{IGNORECASE=1; found=0} /^access-control-allow-origin:/ {found=1} END{exit found ? 0 : 1}' "$tmp_headers"; then
    echo "!! missing Access-Control-Allow-Origin" | tee -a "$REPORT"
  fi
  rm -f "$tmp_headers"
}

container_id_for() {
  local name="$1"
  docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v n="$name" '$2 == n || $2 ~ n {print $1; exit}'
}

section "NexaTech infra CORS diagnosis"
{
  echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "user=$(id -un)"
  echo "origin=$ORIGIN"
  echo "public_url=${PUBLIC_URL:-<not set>}"
  echo "chat_path=$CHAT_PATH"
  echo "report=$REPORT"
} | tee -a "$REPORT"

section "Fast interpretation"
cat <<'EOF' | tee -a "$REPORT"
Read the CORS header matrix first:
- If Kong proxy lacks Access-Control-Allow-Origin but api-gateway has it, the Kong CORS plugin/config is the problem.
- If both Kong and api-gateway lack it, the running api-gateway CORS env/config likely does not include this Origin.
- If local Kong has it but PUBLIC_URL lacks it, check CloudFront forwarding/cache behavior for Origin and OPTIONS.
- For SockJS /ws/chat/info, GET with Origin must include Access-Control-Allow-Origin; OPTIONS alone is not enough.
EOF

section "Files on infra host"
for file in "$KONG_CONFIG" "$RUNTIME_ENV" "$COMPOSE_FILE" "$ENV_DIR/api-gateway.env"; do
  echo "--- $file" | tee -a "$REPORT"
  if [ "$file" = "$RUNTIME_ENV" ] || [ "$file" = "$ENV_DIR/api-gateway.env" ]; then
    redact_env_file "$file" | tee -a "$REPORT"
  else
    read_file "$file" | sed -n '1,220p' | tee -a "$REPORT"
  fi
done

section "Kong CORS origins in rendered config"
if [ -f "$KONG_CONFIG" ]; then
  awk '
    /^[[:space:]]+origins:/ {show=1; print; next}
    show && /^[[:space:]]+[a-zA-Z_]+:/ {show=0}
    show {print}
  ' "$KONG_CONFIG" | tee -a "$REPORT"

  if grep -Fq -- "- $ORIGIN" "$KONG_CONFIG"; then
    echo "origin_exact_match=yes" | tee -a "$REPORT"
  else
    echo "origin_exact_match=no" | tee -a "$REPORT"
  fi
fi

if have docker; then
  section "Docker containers"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$REPORT"

  section "Container env highlights"
  for service in kong api-gateway; do
    cid="$(container_id_for "$service")"
    echo "--- $service ${cid:-<not found>}" | tee -a "$REPORT"
    if [ -n "$cid" ]; then
      docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
        awk -F= -v re="$SENSITIVE_RE" '
          toupper($1) ~ re { print $1"=<redacted>"; next }
          /CORS|ORIGIN|GATEWAY|KONG|SERVER_PORT|CONFIG_SERVER|EUREKA|CHAT|SPRING/ { print }
        ' | sort | tee -a "$REPORT"
    fi
  done

  section "Kong admin API route and plugin snapshot"
  if curl -sS -m "$CURL_TIMEOUT" http://127.0.0.1:8001/status >/dev/null 2>&1; then
    echo "--- /routes/chat-ws-route" | tee -a "$REPORT"
    curl -sS -m "$CURL_TIMEOUT" http://127.0.0.1:8001/routes/chat-ws-route | tee -a "$REPORT"
    echo | tee -a "$REPORT"
    echo "--- /plugins" | tee -a "$REPORT"
    curl -sS -m "$CURL_TIMEOUT" http://127.0.0.1:8001/plugins | tee -a "$REPORT"
    echo | tee -a "$REPORT"
  else
    echo "Kong admin API is not reachable on http://127.0.0.1:8001" | tee -a "$REPORT"
  fi
else
  section "Docker"
  echo "docker command not found" | tee -a "$REPORT"
fi

section "CORS header matrix"
cors_summary "http://127.0.0.1:8000$CHAT_PATH"
cors_summary "http://127.0.0.1:8080$CHAT_PATH"
if [ -n "$PUBLIC_URL" ]; then
  cors_summary "${PUBLIC_URL%/}$CHAT_PATH"
fi

section "Full GET headers with Origin"
curl_headers GET "http://127.0.0.1:8000$CHAT_PATH"
curl_headers GET "http://127.0.0.1:8080$CHAT_PATH"
if [ -n "$PUBLIC_URL" ]; then
  curl_headers GET "${PUBLIC_URL%/}$CHAT_PATH"
fi

section "OPTIONS preflight headers"
curl_headers OPTIONS "http://127.0.0.1:8000$CHAT_PATH"
curl_headers OPTIONS "http://127.0.0.1:8080$CHAT_PATH"
if [ -n "$PUBLIC_URL" ]; then
  curl_headers OPTIONS "${PUBLIC_URL%/}$CHAT_PATH"
fi

if have docker; then
  section "Recent Kong and api-gateway logs"
  for service in kong api-gateway; do
    cid="$(container_id_for "$service")"
    echo "--- $service ${cid:-<not found>}" | tee -a "$REPORT"
    if [ -n "$cid" ]; then
      docker logs --tail 180 "$cid" 2>&1 | \
        grep -Eai 'cors|origin|ws/chat|sockjs|route|plugin|error|warn|exception|denied|forbidden|401|403|404|500|502|503' | tee -a "$REPORT" || true
    fi
  done
fi

section "Done"
echo "Report written to $REPORT" | tee -a "$REPORT"
