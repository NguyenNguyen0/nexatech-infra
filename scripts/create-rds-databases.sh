#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: PGPASSWORD=<password> $0 <rds-host[:port]> <username> [database...]" >&2
  exit 1
fi

endpoint="$1"
username="$2"
shift 2

host="${endpoint%:*}"
port="${endpoint##*:}"
if [ "$host" = "$port" ]; then
  port="5432"
fi

databases=("$@")
if [ "${#databases[@]}" -eq 0 ]; then
  databases=(
    keycloak
    nexatech_identity
    nexatech_users
    nexatech_orders
    nexatech_inventory
    nexatech_payments
    nexatech_shipping
    nexatech_notifications
    nexatech_chats
    nexatech_news
    nexatech_promotions
  )
fi

command -v psql >/dev/null 2>&1 || {
  echo "psql is required" >&2
  exit 1
}

if [ -z "${PGPASSWORD:-}" ]; then
  echo "PGPASSWORD must be set" >&2
  exit 1
fi

for database in "${databases[@]}"; do
  echo "Ensuring database: $database"
  psql \
    --host "$host" \
    --port "$port" \
    --username "$username" \
    --dbname postgres \
    --set ON_ERROR_STOP=1 \
    --tuples-only \
    --no-align \
    --command "SELECT 'CREATE DATABASE ${database}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${database}')\\gexec"
done
