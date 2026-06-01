#!/usr/bin/env bash
set -u

REPORT="${REPORT:-/tmp/nexatech-route-diagnosis-$(hostname)-$(date +%Y%m%d-%H%M%S).log}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
CURL_TIMEOUT="${CURL_TIMEOUT:-8}"
LOG_LINES="${LOG_LINES:-300}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/nexatech/compose}"
RUNTIME_ENV="${RUNTIME_ENV:-/opt/nexatech/runtime.env}"
ENV_DIR="${ENV_DIR:-/opt/nexatech/env}"
CORS_ORIGIN="${CORS_ORIGIN:-https://nexatech-frontend-client.vercel.app}"

GATEWAY_PUBLIC_PATHS=(
  "/actuator/health"
  "/api/v1/auth/openid-configuration"
  "/api/v1/products"
  "/api/v1/categories"
  "/api/v1/brands"
  "/api/v1/reviews"
  "/api/v1/promotions"
  "/api/v1/flash-sales"
  "/api/v1/news"
  "/api/v1/recommend/health"
  "/api/v1/recommend/popular"
  "/api/v1/agent/health"
  "/api/v1/mcp/health"
)

SERVICE_HEALTHS=(
  "discovery-server:8761"
  "config-server:8888"
  "api-gateway:8080"
  "identity-service:8082"
  "user-service:8083"
  "order-service:8084"
  "inventory-service:8085"
  "payment-service:8086"
  "notification-service:8087"
  "storage-service:8088"
  "chat-service:8089"
  "product-service:8090"
  "shipping-service:8091"
  "news-service:8092"
  "promotion-service:8093"
  "mcp-server:8094"
  "recommendation-service:8095"
  "audit-service:8096"
)

SENSITIVE_RE='(PASSWORD|PASS|CLIENT_SECRET|SECRET|TOKEN|CREDENTIAL|AUTHORIZATION|PRIVATE|ACCESS_KEY|SECRET_KEY|API_KEY)'

section() {
  printf '\n\n========== %s ==========\n' "$1" | tee -a "$REPORT"
}

run() {
  local title="$1"
  shift
  section "$title"
  printf '+ %q' "$@" | tee -a "$REPORT"
  printf '\n' | tee -a "$REPORT"
  "$@" >>"$REPORT" 2>&1
  local status=$?
  printf '\n(exit=%s)\n' "$status" | tee -a "$REPORT"
  return 0
}

have() {
  command -v "$1" >/dev/null 2>&1
}

curl_status() {
  local method="$1"
  local url="$2"
  local origin="${3:-}"
  local extra=()

  if [ -n "$origin" ]; then
    extra=(-H "Origin: $origin" -H "Access-Control-Request-Method: GET")
  fi

  curl -k -sS -m "$CURL_TIMEOUT" -o /tmp/nexatech-curl-body.$$ \
    -w 'status=%{http_code} connect=%{time_connect}s starttransfer=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip}:%{remote_port} url=%{url_effective}\n' \
    -X "$method" "${extra[@]}" "$url" 2>&1
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "curl_exit=$code"
  fi
  if [ -s /tmp/nexatech-curl-body.$$ ]; then
    echo "--- body preview ---"
    head -c 700 /tmp/nexatech-curl-body.$$ | tr '\n' ' '
    echo
  fi
  rm -f /tmp/nexatech-curl-body.$$
}

redact_file() {
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

runtime_value() {
  local key="$1"
  read_file "$RUNTIME_ENV" | awk -F= -v k="$key" '$1 == k {print $2; exit}' 2>/dev/null
}

docker_compose_files() {
  if [ -d "$COMPOSE_DIR" ]; then
    find "$COMPOSE_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
  fi
}

docker_logs_for() {
  local name="$1"
  local cid
  cid="$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v n="$name" '$2 == n || $2 ~ n {print $1; exit}')"
  if [ -n "$cid" ]; then
    docker logs --tail "$LOG_LINES" "$cid" 2>&1 | \
      grep -Eai '401|403|unauthor|forbidden|timeout|timed out|connect timed out|connection refused|route|predicate|jwt|issuer|jwk|keycloak|eureka|loadbalancer|no servers|503|502|exception|error' || true
  else
    echo "container not found for $name"
  fi
}

print_hint_summary() {
  section "What to look for"
  cat <<'EOF' | tee -a "$REPORT"
1. If localhost:8080 /actuator/health is not 2xx, the ALB/CloudFront cannot work; inspect api-gateway logs first.
2. If gateway public paths return 401 but direct service paths return 2xx, the running gateway security/config does not match expected permitAll routes.
3. If gateway returns 5xx or times out while direct service health is 2xx, check Eureka registration and lb:// route resolution.
4. If only CloudFront/ALB URL fails but localhost:8080 works, check target group health, security group, Host/X-Forwarded headers, and CloudFront origin policy.
5. If logs mention issuer-uri/JWK/Keycloak for requests that should be public, the request is matching an authenticated security chain or a downstream service is enforcing JWT.
6. If promotion through gateway returns 503, check Eureka for PROMOTION-SERVICE and ensure PROMOTION_SERVICE_URI is lb://promotion-service.
EOF
}

: >"$REPORT"
section "NexaTech public route diagnosis"
{
  echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "user=$(id -un)"
  echo "base_url=$BASE_URL"
  echo "cors_origin=$CORS_ORIGIN"
  echo "report=$REPORT"
  echo "curl_timeout=$CURL_TIMEOUT"
} | tee -a "$REPORT"

run "OS and kernel" uname -a
run "Disk and memory" sh -c "df -h / /opt 2>/dev/null; free -h"

if have curl; then
  section "EC2 metadata"
  TOKEN="$(curl -sS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "${TOKEN:-}" ]; then
    {
      echo "instance-id=$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
      echo "local-ipv4=$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
      echo "public-ipv4=$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
      echo "placement=$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || true)"
    } | tee -a "$REPORT"
  else
    echo "metadata unavailable or IMDSv2 token request failed" | tee -a "$REPORT"
  fi
fi

if have docker; then
  run "Docker version" docker version
  run "Docker containers" docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  run "Docker networks" docker network ls
  run "NexaTech network inspect" docker network inspect nexatech
else
  section "Docker"
  echo "docker command not found" | tee -a "$REPORT"
fi

if have ss; then
  run "Listening ports" ss -ltnp
elif have netstat; then
  run "Listening ports" netstat -ltnp
fi

section "Runtime env redacted"
redact_file "$RUNTIME_ENV" | tee -a "$REPORT"

section "Service env files redacted"
if [ -d "$ENV_DIR" ]; then
  for env_file in "$ENV_DIR"/*.env; do
    [ -e "$env_file" ] || continue
    echo "--- $env_file ---" | tee -a "$REPORT"
    redact_file "$env_file" | tee -a "$REPORT"
  done
else
  echo "missing env dir: $ENV_DIR" | tee -a "$REPORT"
fi

section "Compose files"
if [ -d "$COMPOSE_DIR" ]; then
  for compose_file in $(docker_compose_files); do
    echo "--- $compose_file ---" | tee -a "$REPORT"
    sed -n '1,260p' "$compose_file" | tee -a "$REPORT"
  done
else
  echo "missing compose dir: $COMPOSE_DIR" | tee -a "$REPORT"
fi

if have docker; then
  section "Container env highlights"
  for service in api-gateway config-server discovery-server keycloak identity-service user-service notification-service product-service news-service promotion-service recommendation-service agent-service mcp-server; do
    cid="$(docker ps --format '{{.ID}} {{.Names}}' | awk -v n="$service" '$2 == n || $2 ~ n {print $1; exit}')"
    if [ -n "$cid" ]; then
      echo "--- $service ($cid) ---" | tee -a "$REPORT"
      docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
        awk -F= -v re="$SENSITIVE_RE" '
          toupper($1) ~ re { print $1"=<redacted>"; next }
          /URI|URL|EUREKA|SERVER_PORT|SPRING|GATEWAY|PROMOTION|HOST|PORT|PROFILE|IMAGE|KAFKA/ { print }
        ' | sort | tee -a "$REPORT"
    fi
  done
fi

if have curl; then
  APP1_PRIVATE_IP="${APP1_PRIVATE_IP:-$(runtime_value APP1_PRIVATE_IP)}"
  APP2_PRIVATE_IP="${APP2_PRIVATE_IP:-$(runtime_value APP2_PRIVATE_IP)}"
  APP1_HOST="${APP1_PRIVATE_IP:-127.0.0.1}"
  APP2_HOST="${APP2_PRIVATE_IP:-127.0.0.1}"

  section "Local service health checks"
  for item in "${SERVICE_HEALTHS[@]}"; do
    name="${item%%:*}"
    port="${item##*:}"
    echo "--- $name http://127.0.0.1:$port/actuator/health ---" | tee -a "$REPORT"
    curl_status GET "http://127.0.0.1:$port/actuator/health" | tee -a "$REPORT"
  done

  section "Gateway public route checks"
  for path in "${GATEWAY_PUBLIC_PATHS[@]}"; do
    echo "--- GET $BASE_URL$path ---" | tee -a "$REPORT"
    curl_status GET "$BASE_URL$path" | tee -a "$REPORT"
  done

  section "Gateway CORS preflight checks"
  for path in "/api/v1/products" "/api/v1/news" "/api/v1/auth/login"; do
    echo "--- OPTIONS $BASE_URL$path ---" | tee -a "$REPORT"
    curl_status OPTIONS "$BASE_URL$path" "$CORS_ORIGIN" | tee -a "$REPORT"
  done

  section "Direct service public endpoint probes"
  for url in \
    "http://$APP1_HOST:8090/api/v1/products" \
    "http://$APP1_HOST:8090/api/v1/categories" \
    "http://$APP2_HOST:8092/api/v1/news" \
    "http://$APP2_HOST:8093/api/v1/promotions" \
    "http://$APP2_HOST:8095/recommend/popular" \
    "http://$APP2_HOST:8097/health"; do
    echo "--- GET $url ---" | tee -a "$REPORT"
    curl_status GET "$url" | tee -a "$REPORT"
  done

  section "Eureka applications"
  curl -sS -m "$CURL_TIMEOUT" -H 'Accept: application/json' http://127.0.0.1:8761/eureka/apps | tee -a "$REPORT" || true

  section "Keycloak issuer and well-known"
  for url in \
    "http://127.0.0.1:9000/realms/nexatech" \
    "http://127.0.0.1:9000/realms/nexatech/.well-known/openid-configuration"; do
    echo "--- GET $url ---" | tee -a "$REPORT"
    curl_status GET "$url" | tee -a "$REPORT"
  done
else
  section "curl checks"
  echo "curl command not found" | tee -a "$REPORT"
fi

if have docker; then
  section "Recent suspicious logs"
  for service in api-gateway config-server discovery-server keycloak identity-service user-service notification-service product-service news-service promotion-service recommendation-service agent-service mcp-server; do
    echo "--- $service ---" | tee -a "$REPORT"
    docker_logs_for "$service" | tee -a "$REPORT"
  done
fi

print_hint_summary

section "Done"
echo "Report written to $REPORT" | tee -a "$REPORT"
