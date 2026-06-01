#!/usr/bin/env bash
set -u

INVENTORY="${INVENTORY:-ansible/inventory/dev.ini}"
HOSTS="${HOSTS:-all}"
LOG_LINES="${LOG_LINES:-500}"
SINCE="${SINCE:-}"
OUT_DIR="${OUT_DIR:-logs}"
SERVICES="${SERVICES:-kong api-gateway identity-service}"
FILTER="${FILTER:-401|403|unauthor|forbidden|cors|origin|authorization|bearer|cookie|session|token|jwt|jwk|issuer|keycloak|login|logout|refresh|exception|error|warn|denied|route|gateway|upstream|502|503|500}"
MODE="remote"
STDOUT_ONLY=0
DOCKER=(docker)

usage() {
  cat <<'USAGE'
Usage:
  scripts/collect-auth-logs.sh
  scripts/collect-auth-logs.sh --inventory ansible/inventory/dev.ini --hosts all
  scripts/collect-auth-logs.sh --local

Options:
  --inventory PATH   Ansible inventory for remote collection. Default: ansible/inventory/dev.ini
  --hosts PATTERN    Ansible host pattern. Default: all
  --local            Collect from Docker on the current host.
  --lines N          docker logs --tail value. Default: 500
  --since VALUE      Optional docker logs --since value, for example 30m, 2h, 2026-06-01T10:00:00
  --services LIST    Space-separated container names. Default: "kong api-gateway identity-service"
  --out-dir DIR      Local output directory for remote report. Default: logs
  --stdout           Print only to stdout. Useful when called by Ansible script module.

Environment variables mirror the option names:
  INVENTORY, HOSTS, LOG_LINES, SINCE, SERVICES, OUT_DIR, FILTER
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --inventory)
      INVENTORY="$2"
      shift 2
      ;;
    --hosts)
      HOSTS="$2"
      shift 2
      ;;
    --local)
      MODE="local"
      shift
      ;;
    --lines)
      LOG_LINES="$2"
      shift 2
      ;;
    --since)
      SINCE="$2"
      shift 2
      ;;
    --services)
      SERVICES="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --stdout)
      STDOUT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n\n========== %s ==========\n' "$1"
}

container_id_for() {
  local name="$1"
  "${DOCKER[@]}" ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk -v n="$name" '$2 == n || $2 ~ n {print $1; exit}'
}

init_docker() {
  if ! have docker; then
    return 1
  fi

  if docker ps >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi

  if have sudo && sudo -n docker ps >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    return 0
  fi

  return 1
}

collect_local() {
  section "NexaTech auth path logs"
  {
    echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "user=$(id -un)"
    echo "services=$SERVICES"
    echo "log_lines=$LOG_LINES"
    echo "since=${SINCE:-<not set>}"
    echo "filter=$FILTER"
  }

  if ! init_docker; then
    section "Docker"
    echo "docker command not found or current user cannot access Docker. Try running on the host with sudo."
    return 0
  fi

  section "Containers"
  "${DOCKER[@]}" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1

  for service in $SERVICES; do
    local cid
    cid="$(container_id_for "$service")"
    section "$service"
    echo "container=${cid:-<not found>}"

    if [ -z "$cid" ]; then
      continue
    fi

    echo "--- inspect"
    "${DOCKER[@]}" inspect "$cid" --format 'name={{.Name}} image={{.Config.Image}} status={{.State.Status}} started={{.State.StartedAt}} restart_count={{.RestartCount}}' 2>&1 || true

    local log_args
    log_args=(--tail "$LOG_LINES")
    if [ -n "$SINCE" ]; then
      log_args+=(--since "$SINCE")
    fi

    echo "--- recent filtered logs"
    "${DOCKER[@]}" logs "${log_args[@]}" "$cid" 2>&1 | grep -Eai "$FILTER" || true

    echo "--- recent raw tail"
    "${DOCKER[@]}" logs --tail 80 "$cid" 2>&1 || true
  done
}

collect_remote() {
  if ! have ansible; then
    echo "ansible command not found. Install Ansible or run with --local on the EC2 host." >&2
    exit 1
  fi

  if [ ! -f "$INVENTORY" ]; then
    echo "inventory not found: $INVENTORY" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"
  local report
  report="$OUT_DIR/auth-path-logs-$(date +%Y%m%d-%H%M%S).log"

  {
    echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "inventory=$INVENTORY"
    echo "hosts=$HOSTS"
    echo "services=$SERVICES"
    echo "log_lines=$LOG_LINES"
    echo "since=${SINCE:-<not set>}"
    echo
  } >"$report"

  local args
  args="--local --stdout --lines $LOG_LINES --services '$SERVICES'"
  if [ -n "$SINCE" ]; then
    args="$args --since '$SINCE'"
  fi

  echo "Collecting logs from '$HOSTS' into $report"
  ansible "$HOSTS" -i "$INVENTORY" -m script -a "$0 $args" >>"$report" 2>&1
  echo "Report written to $report"
}

if [ "$MODE" = "local" ]; then
  if [ "$STDOUT_ONLY" -eq 1 ]; then
    collect_local
  else
    REPORT="${REPORT:-/tmp/nexatech-auth-path-logs-$(hostname)-$(date +%Y%m%d-%H%M%S).log}"
    collect_local | tee "$REPORT"
    echo "Report written to $REPORT"
  fi
else
  collect_remote
fi
