#!/usr/bin/env bash
set -u

KONG_CONTAINER="${KONG_CONTAINER:-kong}"
KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://127.0.0.1:8001}"
KONG_PROXY_URL="${KONG_PROXY_URL:-http://127.0.0.1:8000}"
KONG_CONFIG_HOST="${KONG_CONFIG_HOST:-/opt/nexatech/kong/kong.yml}"
KONG_CONFIG_CONTAINER="${KONG_CONFIG_CONTAINER:-/kong/declarative/kong.yml}"
ORIGIN="${ORIGIN:-}"
REPORT="${REPORT:-/tmp/nexatech-kong-env-$(hostname)-$(date +%Y%m%d-%H%M%S).log}"
CURL_TIMEOUT="${CURL_TIMEOUT:-6}"

SENSITIVE_RE='(PASSWORD|PASS|CLIENT_SECRET|SECRET|TOKEN|CREDENTIAL|AUTHORIZATION|PRIVATE|ACCESS_KEY|SECRET_KEY|API_KEY)'

usage() {
  cat <<'USAGE'
Usage:
  scripts/check-kong-env.sh
  ORIGIN=https://www.nexatech.website scripts/check-kong-env.sh

Environment:
  KONG_CONTAINER          Container name match. Default: kong
  KONG_ADMIN_URL          Default: http://127.0.0.1:8001
  KONG_PROXY_URL          Default: http://127.0.0.1:8000
  KONG_CONFIG_HOST        Default: /opt/nexatech/kong/kong.yml
  KONG_CONFIG_CONTAINER   Default: /kong/declarative/kong.yml
  ORIGIN                  Optional. If set, test CORS against Kong proxy.
  REPORT                  Optional report path.

Run this on the infra EC2 host.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

: >"$REPORT"

section() {
  printf '\n\n========== %s ==========\n' "$1" | tee -a "$REPORT"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

container_id_for() {
  local name="$1"
  docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v n="$name" '$2 == n || $2 ~ n {print $1; exit}'
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

curl_get() {
  local url="$1"
  curl -sS -m "$CURL_TIMEOUT" "$url" 2>&1 || true
}

section "Kong env check"
{
  echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "user=$(id -un)"
  echo "kong_container_match=$KONG_CONTAINER"
  echo "kong_admin_url=$KONG_ADMIN_URL"
  echo "kong_proxy_url=$KONG_PROXY_URL"
  echo "kong_config_host=$KONG_CONFIG_HOST"
  echo "kong_config_container=$KONG_CONFIG_CONTAINER"
  echo "origin=${ORIGIN:-<not set>}"
  echo "report=$REPORT"
} | tee -a "$REPORT"

if ! have docker; then
  section "Docker"
  echo "docker command not found" | tee -a "$REPORT"
  exit 1
fi

KONG_CID="$(container_id_for "$KONG_CONTAINER")"
if [ -z "$KONG_CID" ]; then
  section "Kong container"
  echo "Kong container not found with match: $KONG_CONTAINER" | tee -a "$REPORT"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$REPORT"
  exit 1
fi

section "Container summary"
docker ps --filter "id=$KONG_CID" --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$REPORT"

section "Container environment"
docker inspect "$KONG_CID" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
  awk -F= -v re="$SENSITIVE_RE" '
    toupper($1) ~ re { print $1"=<redacted>"; next }
    { print }
  ' | sort | tee -a "$REPORT"

section "Container mounts"
docker inspect "$KONG_CID" --format '{{range .Mounts}}{{println .Source " -> " .Destination " (" .Mode ")"}}{{end}}' 2>/dev/null | tee -a "$REPORT"

section "Host declarative config"
read_file "$KONG_CONFIG_HOST" | sed -n '1,220p' | tee -a "$REPORT"

section "Container declarative config"
docker exec "$KONG_CID" sh -c "sed -n '1,220p' '$KONG_CONFIG_CONTAINER'" 2>&1 | tee -a "$REPORT"

section "CORS origins in host config"
read_file "$KONG_CONFIG_HOST" | awk '
  /^[[:space:]]+origins:/ {show=1; print; next}
  show && /^[[:space:]]+[a-zA-Z_]+:/ {show=0}
  show {print}
' | tee -a "$REPORT"

section "Kong admin status"
curl_get "$KONG_ADMIN_URL/status" | tee -a "$REPORT"

section "Kong admin plugins"
curl_get "$KONG_ADMIN_URL/plugins" | tee -a "$REPORT"
echo | tee -a "$REPORT"

section "Kong admin routes"
curl_get "$KONG_ADMIN_URL/routes" | tee -a "$REPORT"
echo | tee -a "$REPORT"

if [ -n "$ORIGIN" ]; then
  section "CORS probe through Kong proxy"
  echo "--- GET $KONG_PROXY_URL/ws/chat/info" | tee -a "$REPORT"
  curl -k -sS -m "$CURL_TIMEOUT" \
    -D - -o /tmp/nexatech-kong-cors-body.$$ \
    -H "Origin: $ORIGIN" \
    "$KONG_PROXY_URL/ws/chat/info?t=$(date +%s)" 2>&1 | tee -a "$REPORT"
  if [ -s /tmp/nexatech-kong-cors-body.$$ ]; then
    echo "--- body preview" | tee -a "$REPORT"
    head -c 500 /tmp/nexatech-kong-cors-body.$$ | tr '\n' ' ' | tee -a "$REPORT"
    echo | tee -a "$REPORT"
  fi
  rm -f /tmp/nexatech-kong-cors-body.$$

  section "Origin exact match in host config"
  if grep -Fq -- "- $ORIGIN" "$KONG_CONFIG_HOST"; then
    echo "origin_exact_match=yes" | tee -a "$REPORT"
  else
    echo "origin_exact_match=no" | tee -a "$REPORT"
  fi
fi

section "Recent Kong logs"
docker logs --tail 120 "$KONG_CID" 2>&1 | \
  grep -Eai 'declarative|config|cors|origin|plugin|error|warn|reload|ws/chat' | tee -a "$REPORT" || true

section "Done"
echo "Report written to $REPORT" | tee -a "$REPORT"
