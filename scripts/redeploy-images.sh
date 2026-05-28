#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${INVENTORY:-$ROOT_DIR/ansible/inventory/dev.ini}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-trungnguyen918}"
TARGET="${TARGET:-all}"
VAULT_ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/redeploy-images.sh <image-tag> [--target all|infra|app] [--inventory path] [--namespace dockerhub-namespace] [--ask-vault-pass]

Examples:
  scripts/redeploy-images.sh 1444753
  scripts/redeploy-images.sh 1444753 --target app
  DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... scripts/redeploy-images.sh 1444753 --ask-vault-pass

Environment:
  INVENTORY             Defaults to ansible/inventory/dev.ini
  DOCKERHUB_NAMESPACE   Defaults to trungnguyen918
  DOCKERHUB_USERNAME    Optional. Used for docker login on EC2 before pull.
  DOCKERHUB_TOKEN       Optional. Used for docker login on EC2 before pull.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

IMAGE_TAG="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --inventory|-i)
      INVENTORY="${2:-}"
      shift 2
      ;;
    --namespace)
      DOCKERHUB_NAMESPACE="${2:-}"
      shift 2
      ;;
    --ask-vault-pass)
      VAULT_ARGS+=(--ask-vault-pass)
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$TARGET" in
  all|infra|app) ;;
  *)
    echo "--target must be one of: all, infra, app" >&2
    exit 1
    ;;
esac

if [ ! -f "$INVENTORY" ]; then
  echo "Inventory not found: $INVENTORY" >&2
  echo "Render it first with scripts/render-inventory.sh, or pass --inventory." >&2
  exit 1
fi

command -v ansible-playbook >/dev/null 2>&1 || {
  echo "ansible-playbook is required" >&2
  exit 1
}

EXTRA_VARS=(
  "dockerhub_username=${DOCKERHUB_USERNAME:-}"
  "dockerhub_token=${DOCKERHUB_TOKEN:-}"
  "dockerhub_namespace=$DOCKERHUB_NAMESPACE"
  "image_tag=$IMAGE_TAG"
)

run_playbook() {
  local playbook="$1"
  local limit="$2"

  echo "Deploying $limit with image tag: $IMAGE_TAG"
  ansible-playbook \
    -i "$INVENTORY" \
    "$ROOT_DIR/ansible/playbooks/$playbook" \
    --limit "$limit" \
    --extra-vars "${EXTRA_VARS[*]}" \
    "${VAULT_ARGS[@]}"
}

case "$TARGET" in
  all)
    run_playbook deploy-infra.yml infra
    run_playbook deploy-app.yml app
    ;;
  infra)
    run_playbook deploy-infra.yml infra
    ;;
  app)
    run_playbook deploy-app.yml app
    ;;
esac

echo "Redeploy complete."
