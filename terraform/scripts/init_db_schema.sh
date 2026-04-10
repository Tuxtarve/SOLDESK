#!/usr/bin/env bash
set -euo pipefail

if ! command -v mysql >/dev/null 2>&1; then
  echo "mysql client not found. Install mysql client first (e.g., mysql-community-client) and re-run."
  exit 1
fi

: "${DB_HOST:?DB_HOST required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASSWORD:?DB_PASSWORD required}"
: "${DB_NAME:?DB_NAME required}"
: "${CREATE_SQL:?CREATE_SQL required}"
: "${INSERT_SQL:?INSERT_SQL required}"

if [ ! -f "$CREATE_SQL" ]; then
  echo "create.sql not found at: $CREATE_SQL"
  exit 1
fi
if [ ! -f "$INSERT_SQL" ]; then
  echo "Insert.sql not found at: $INSERT_SQL"
  exit 1
fi

echo "=== DB schema init (writer: ${DB_HOST}) ==="
echo "Applying DDL: $CREATE_SQL"
MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" --protocol=tcp < "$CREATE_SQL"

echo "Applying seed: $INSERT_SQL"
MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" --protocol=tcp < "$INSERT_SQL"

echo "Verifying basic objects..."
MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" --protocol=tcp -D "$DB_NAME" -e \
  "SHOW TABLES; SELECT COUNT(*) AS movies_count FROM movies; SELECT COUNT(*) AS theaters_count FROM theaters;" >/dev/null

echo "=== DB schema init complete ==="

