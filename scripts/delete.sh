#!/usr/bin/env bash
set -Eeuo pipefail

# When kubectl cannot reach API server (auth/network), it may appear to "hang".
# Force request-level timeouts so the script fails fast with a useful error.
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-20s}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-180s}"

_on_err() {
  local exit_code=$?
  echo "ERROR: delete.sh failed (exit=$exit_code) at line=$LINENO" >&2
  echo "ERROR: last_command=$BASH_COMMAND" >&2
  exit "$exit_code"
}
trap _on_err ERR

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
# How to run mysql client:
# - k8s-pod (default): create a temporary mysql client pod and exec into it
# - local: run local `mysql` binary directly (no temp pod; avoids pod Ready timeouts)
MYSQL_CLIENT_MODE="${MYSQL_CLIENT_MODE:-k8s-pod}"

_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 127; }
}

_need kubectl

_k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

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
echo "mysql_client_mode=$MYSQL_CLIENT_MODE"

if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  _need mysql
  : "${DB_HOST:?DB_HOST required when MYSQL_CLIENT_MODE=local}"
  : "${DB_USER:?DB_USER required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PASSWORD:?DB_PASSWORD required when MYSQL_CLIENT_MODE=local}"
  : "${DB_NAME:?DB_NAME required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PORT:?DB_PORT required when MYSQL_CLIENT_MODE=local}"
  # Redis invalidation still uses cluster lookup unless explicitly provided.
  REDIS_HOST="${REDIS_HOST:-}"
else
  DB_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_WRITER_HOST}' | base64 -d | tr -d '\r\n')"
  DB_USER="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_USER}' | base64 -d | tr -d '\r\n')"
  DB_PASSWORD="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | tr -d '\r\n')"
  DB_NAME="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_NAME}' | tr -d '\r\n')"
  DB_PORT="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_PORT}' | tr -d '\r\n')"
  REDIS_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.REDIS_HOST}' 2>/dev/null | base64 -d | tr -d '\r\n' || true)"
fi
if [[ -z "$REDIS_HOST" ]]; then
  if [[ "$MYSQL_CLIENT_MODE" != "local" ]]; then
    REDIS_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.ELASTICACHE_PRIMARY_ENDPOINT}' 2>/dev/null | base64 -d | tr -d '\r\n' || true)"
  fi
fi
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  REDIS_PORT="${REDIS_PORT:-}"
  REDIS_DB_CACHE="${REDIS_DB_CACHE:-}"
else
  REDIS_PORT="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.REDIS_PORT}' | tr -d '\r\n')"
  REDIS_DB_CACHE="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.ELASTICACHE_LOGICAL_DB_CACHE}' | tr -d '\r\n')"
fi

if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_NAME}" || -z "${DB_PORT}" ]]; then
  echo "ERROR: failed to load DB settings from $NS/{ticketing-secrets,ticketing-config}" >&2
  exit 1
fi

cleanup() {
  _k -n "$NS" delete pod "$MYSQL_POD" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$MYSQL_CLIENT_MODE" == "k8s-pod" ]]; then
  _k -n "$NS" run "$MYSQL_POD" \
    --image="$MYSQL_IMAGE" \
    --restart=Never \
    --command -- sh -lc "sleep 3600" >/dev/null

  if ! _k -n "$NS" wait --for=condition=Ready pod/"$MYSQL_POD" --timeout="$POD_READY_TIMEOUT" >/dev/null; then
    echo "ERROR: mysql client pod not Ready: $MYSQL_POD (timeout=$POD_READY_TIMEOUT)" >&2
    echo "--- pod status ---" >&2
    _k -n "$NS" get pod "$MYSQL_POD" -o wide >&2 || true
    echo "--- pod describe (tail) ---" >&2
    _k -n "$NS" describe pod "$MYSQL_POD" 2>&1 | tail -n 80 >&2 || true
    echo "--- namespace events (tail) ---" >&2
    _k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -n 80 >&2 || true
    exit 1
  fi
fi

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

-- Wipe mode: MySQL IF/THEN is not allowed outside stored programs.
-- Use WHERE @do_wipe to conditionally delete all rows (fast enough for test env).
DELETE FROM concert_booking WHERE @do_wipe;
DELETE FROM concert_booking_seats WHERE @do_wipe;
DELETE FROM concert_payment WHERE @do_wipe;
DELETE FROM users
WHERE @do_wipe_users
  AND user_id BETWEEN @uid_min AND @uid_max
  AND name LIKE CONCAT(@user_prefix, '%');

-- If wipe ran, show post counts and exit early.
SELECT COUNT(*) AS concert_booking_rows_total FROM concert_booking;
SELECT COUNT(*) AS concert_booking_seats_rows_total FROM concert_booking_seats;
SELECT COUNT(*) AS concert_payment_rows_total FROM concert_payment;

-- Find target show_id (or use explicit one).
SET @target_show_id := IF(@do_wipe, NULL, IFNULL(@explicit_show_id, (
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
)));

SELECT @target_show_id AS target_show_id;
SELECT concert_id INTO @target_concert_id
FROM concert_shows
WHERE show_id = @target_show_id;
SELECT @target_concert_id AS target_concert_id;

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

-- Sync remain_count after cleanup (cache reads this column)
UPDATE concert_shows cs
SET remain_count = GREATEST(0, cs.total_count - IFNULL((
  SELECT COUNT(*) FROM concert_booking_seats cbs
  WHERE cbs.show_id = cs.show_id AND UPPER(COALESCE(cbs.status, '')) = 'ACTIVE'
), 0))
WHERE (@do_wipe AND 1=1) OR cs.show_id = @target_show_id;

SELECT show_id, total_count, remain_count
FROM concert_shows
WHERE show_id = @target_show_id;

-- Counts after delete
SELECT COUNT(*) AS concert_booking_rows_after
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

-- For bash parsing (tsv): __IDS__  <show_id>  <concert_id>
SELECT '__IDS__' AS tag, @target_show_id AS show_id, @target_concert_id AS concert_id;
EOF
)"

echo "Running cleanup SQL via mysql client pod: $MYSQL_POD"
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  echo "Running cleanup SQL via local mysql client"
  OUT="$(MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" -N -B -e "$SQL")"
else
  echo "Running cleanup SQL via mysql client pod: $MYSQL_POD"
  OUT="$(_k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -N -B -e \"$SQL\"")"
fi
printf '%s\n' "$OUT"

IDS_LINE="$(printf '%s\n' "$OUT" | grep -F '__IDS__' | tail -n 1 || true)"
TARGET_SHOW_ID=""
TARGET_CONCERT_ID=""
if [[ -n "$IDS_LINE" ]]; then
  IFS=$'\t' read -r _tag TARGET_SHOW_ID TARGET_CONCERT_ID <<< "$IDS_LINE" || true
fi

if [[ -n "$REDIS_HOST" && -n "$TARGET_SHOW_ID" && -n "$TARGET_CONCERT_ID" ]]; then
  echo "Invalidating Redis read-cache keys (show_id=$TARGET_SHOW_ID concert_id=$TARGET_CONCERT_ID db=$REDIS_DB_CACHE)"
  REDIS_POD="redis-loadtest-clean-$(date +%s)"
  _k -n "$NS" delete pod "$REDIS_POD" --ignore-not-found >/dev/null 2>&1 || true
  _k -n "$NS" run "$REDIS_POD" --image="redis:7-alpine" --restart=Never --command -- sh -lc "sleep 3600" >/dev/null
  _k -n "$NS" wait --for=condition=Ready pod/"$REDIS_POD" --timeout="$POD_READY_TIMEOUT" >/dev/null
  _k -n "$NS" exec "$REDIS_POD" -- sh -lc \
    "redis-cli -h \"$REDIS_HOST\" -p \"$REDIS_PORT\" -n \"${REDIS_DB_CACHE:-0}\" DEL \
      \"concert:show:${TARGET_SHOW_ID}:read:v2\" \
      \"concert:shows_meta:${TARGET_CONCERT_ID}:read:v1\" \
      \"concert:bootstrap:${TARGET_CONCERT_ID}:read:v1\" >/dev/null || true"
  _k -n "$NS" delete pod "$REDIS_POD" --ignore-not-found >/dev/null 2>&1 || true
else
  echo "Skip Redis invalidation (missing REDIS_HOST or target ids)."
fi

echo "=== done ==="

