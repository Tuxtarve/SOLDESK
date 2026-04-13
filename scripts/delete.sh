#!/usr/bin/env bash
set -euo pipefail

# Deletes ONLY rows created by:
#   python3 ../scripts/sqs_load_real_concert.py -n 30000 --spread-users 30000 --via-was ...
#
# Safety constraints (must all match):
# - concert title = DEFAULT_CONCERT_TITLE in sqs_load_real_concert.py
# - users user_id in [1..30000]
# - users.name starts with "sqs-load-concert-" (created/ensured by the load script)
#
# Notes:
# - Deleting from concert_booking cascades to concert_booking_seats + concert_payment (FK ON DELETE CASCADE).

NS="${NS:-ticketing}"
UID_MIN="${UID_MIN:-1}"
UID_MAX="${UID_MAX:-30000}"
USER_NAME_PREFIX="${USER_NAME_PREFIX:-sqs-load-concert-}"
CONCERT_TITLE="${CONCERT_TITLE:-2026 봄 페스티벌 LIVE - 5만석}"
# Optional: if set, skip auto-detect query and delete only this show_id.
SHOW_ID="${SHOW_ID:-}"
# If true, wipe all concert booking tables (fast reset for test env).
WIPE_CONCERT_TABLES="${WIPE_CONCERT_TABLES:-false}"
# Optional: also delete loadtest users (name prefix) after wiping.
WIPE_LOADTEST_USERS="${WIPE_LOADTEST_USERS:-false}"

# mysql client pod (ephemeral)
MYSQL_POD="${MYSQL_POD:-db-loadtest-clean-$(date +%s)}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8}"

_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 127; }
}

_need kubectl

echo "=== loadtest cleanup (concert via-was) ==="
echo "namespace=$NS"
echo "uid_range=$UID_MIN..$UID_MAX"
echo "user_name_prefix=${USER_NAME_PREFIX}*"
echo "concert_title=$CONCERT_TITLE"
if [[ -n "$SHOW_ID" ]]; then
  echo "show_id=$SHOW_ID (explicit)"
else
  echo "show_id=(auto-detect by max matching bookings)"
fi
echo "wipe_concert_tables=$WIPE_CONCERT_TABLES"
echo "wipe_loadtest_users=$WIPE_LOADTEST_USERS"

DB_HOST="$(kubectl -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_WRITER_HOST}' | base64 -d | tr -d '\r\n')"
DB_USER="$(kubectl -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_USER}' | base64 -d | tr -d '\r\n')"
DB_PASSWORD="$(kubectl -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | tr -d '\r\n')"
DB_NAME="$(kubectl -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_NAME}' | tr -d '\r\n')"
DB_PORT="$(kubectl -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_PORT}' | tr -d '\r\n')"

if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_NAME}" || -z "${DB_PORT}" ]]; then
  echo "ERROR: failed to load DB settings from $NS/{ticketing-secrets,ticketing-config}" >&2
  exit 1
fi

cleanup() {
  kubectl -n "$NS" delete pod "$MYSQL_POD" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NS" run "$MYSQL_POD" \
  --image="$MYSQL_IMAGE" \
  --restart=Never \
  --command -- sh -lc "sleep 3600" >/dev/null

kubectl -n "$NS" wait --for=condition=Ready pod/"$MYSQL_POD" --timeout=180s >/dev/null

_sql_escape_squote() {
  # escape for SQL single-quoted strings:  '  ->  ''
  local s="${1-}"
  s="${s//\'/\'\'}"
  printf '%s' "$s"
}

USER_NAME_PREFIX_ESC="$(_sql_escape_squote "$USER_NAME_PREFIX")"
CONCERT_TITLE_ESC="$(_sql_escape_squote "$CONCERT_TITLE")"

SQL="$(cat <<EOF
SET @uid_min := $UID_MIN;
SET @uid_max := $UID_MAX;
SET @user_prefix := '$USER_NAME_PREFIX_ESC';
SET @concert_title := '$CONCERT_TITLE_ESC';
SET @explicit_show_id := ${SHOW_ID:-NULL};
SET @wipe_tables := ${WIPE_CONCERT_TABLES};
SET @wipe_users := ${WIPE_LOADTEST_USERS};

-- Fast path: wipe whole tables (test env reset)
-- NOTE: this removes ALL rows in these tables, not just loadtest rows.
-- Use only when you truly want a clean slate.
SET @do_wipe := (LOWER(COALESCE(@wipe_tables, 'false')) IN ('1','true','yes','y','on'));
SET @do_wipe_users := (LOWER(COALESCE(@wipe_users, 'false')) IN ('1','true','yes','y','on'));

SELECT @do_wipe AS will_wipe_concert_tables, @do_wipe_users AS will_wipe_loadtest_users;

-- If wiping, do it and stop further deletes.
-- We keep it in a single mysql -e run for speed.
DO
  IF @do_wipe THEN
    SET FOREIGN_KEY_CHECKS=0;
    TRUNCATE TABLE concert_payment;
    TRUNCATE TABLE concert_booking_seats;
    TRUNCATE TABLE concert_booking;
    SET FOREIGN_KEY_CHECKS=1;
    IF @do_wipe_users THEN
      DELETE FROM users
      WHERE user_id BETWEEN @uid_min AND @uid_max
        AND name LIKE CONCAT(@user_prefix, '%');
    END IF;
  END IF;

-- If wipe ran, show post counts and exit early.
SELECT COUNT(*) AS concert_booking_rows_total FROM concert_booking;
SELECT COUNT(*) AS concert_booking_seats_rows_total FROM concert_booking_seats;
SELECT COUNT(*) AS concert_payment_rows_total FROM concert_payment;

-- Find target show_id (or use explicit one).
SET @target_show_id := IFNULL(@explicit_show_id, (
  SELECT t.show_id FROM (
    SELECT cb.show_id AS show_id, COUNT(*) AS bookings
    FROM concert_booking cb
    JOIN users u ON u.user_id = cb.user_id
    JOIN concert_shows cs ON cs.show_id = cb.show_id
    JOIN concerts c ON c.concert_id = cs.concert_id
    WHERE cb.user_id BETWEEN @uid_min AND @uid_max
      AND u.name LIKE CONCAT(@user_prefix, '%')
      AND c.title = @concert_title
    GROUP BY cb.show_id
    ORDER BY bookings DESC
    LIMIT 1
  ) t
));

SELECT @target_show_id AS target_show_id;

-- Materialize only the booking_ids we intend to delete (avoid repeating joins).
DROP TEMPORARY TABLE IF EXISTS _loadtest_booking_ids;
CREATE TEMPORARY TABLE _loadtest_booking_ids (
  booking_id BIGINT PRIMARY KEY
) ENGINE=MEMORY;

INSERT INTO _loadtest_booking_ids (booking_id)
SELECT cb.booking_id
FROM concert_booking cb
JOIN users u ON u.user_id = cb.user_id
JOIN concert_shows cs ON cs.show_id = cb.show_id
JOIN concerts c ON c.concert_id = cs.concert_id
WHERE cb.show_id = @target_show_id
  AND cb.user_id BETWEEN @uid_min AND @uid_max
  AND u.name LIKE CONCAT(@user_prefix, '%')
  AND c.title = @concert_title;

SELECT COUNT(*) AS target_booking_ids FROM _loadtest_booking_ids;

-- Counts before delete
SELECT COUNT(*) AS concert_booking_rows
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

SELECT COUNT(*) AS concert_booking_seats_rows
FROM concert_booking_seats s
JOIN _loadtest_booking_ids t ON t.booking_id = s.booking_id;

SELECT COUNT(*) AS concert_payment_rows
FROM concert_payment p
JOIN _loadtest_booking_ids t ON t.booking_id = p.booking_id;

-- Delete (cascades to seats/payment)
DELETE cb
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

-- Counts after delete
SELECT COUNT(*) AS concert_booking_rows_after
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;
EOF
)"

echo "Running cleanup SQL via mysql client pod: $MYSQL_POD"
kubectl -n "$NS" exec "$MYSQL_POD" -- sh -lc \
  "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -e \"$SQL\""

echo "=== done ==="

