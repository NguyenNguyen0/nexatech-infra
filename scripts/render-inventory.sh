#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 terraform-output.json ansible/inventory/dev.ini" >&2
  exit 1
fi

input="$1"
output="$2"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required to render inventory" >&2
  exit 1
}

infra_public="$(jq -r '.ec2_public_ips.value["infra-1"]' "$input")"
infra_private="$(jq -r '.ec2_private_ips.value["infra-1"]' "$input")"
app1_public="$(jq -r '.ec2_public_ips.value["app-1"]' "$input")"
app1_private="$(jq -r '.ec2_private_ips.value["app-1"]' "$input")"
app2_public="$(jq -r '.ec2_public_ips.value["app-2"] // empty' "$input")"
app2_private="$(jq -r '.ec2_private_ips.value["app-2"] // empty' "$input")"

mkdir -p "$(dirname "$output")"

{
  echo "[infra]"
  echo "infra-1 ansible_host=${infra_public} private_ip=${infra_private} app_group=infra compose_file=infra.docker-compose.yml"
  echo
  echo "[app]"
  echo "app-1 ansible_host=${app1_public} private_ip=${app1_private} app_group=app-1 compose_file=app-1.docker-compose.yml"
  if [ -n "$app2_public" ]; then
    echo "app-2 ansible_host=${app2_public} private_ip=${app2_private} app_group=app-2 compose_file=app-2.docker-compose.yml"
  fi
  echo
  echo "[all:vars]"
  echo "ansible_user=ubuntu"
  echo "aws_region=$(jq -r '.aws_region.value // "ap-southeast-1"' "$input" 2>/dev/null || echo ap-southeast-1)"
  echo "ecr_registry="
  echo "dockerhub_namespace=${DOCKERHUB_NAMESPACE:-}"
  echo "image_tag=${IMAGE_TAG:-latest}"
} > "$output"
