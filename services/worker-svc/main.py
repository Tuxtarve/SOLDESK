"""
SQS FIFO Worker — 예매 메시지 처리.
theaters_write._commit_booking_sync / concert_write._commit_concert_booking_sync 로직을 재사용.
"""
import os
import json
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
import redis
import pymysql
import time
from botocore.config import Config

logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker-svc")

AWS_REGION    = os.getenv("AWS_REGION", "")
SQS_QUEUE_URL = (os.getenv("SQS_QUEUE_URL") or "").strip()
DB_HOST       = os.getenv("DB_WRITER_HOST", "127.0.0.1")
DB_PORT       = int(os.getenv("DB_PORT", "3306"))
DB_NAME       = os.getenv("DB_NAME", "ticketing")
DB_USER       = os.getenv("DB_USER", "root")
DB_PASSWORD   = os.getenv("DB_PASSWORD", "")
ELASTICACHE_PRIMARY_ENDPOINT = os.getenv("ELASTICACHE_PRIMARY_ENDPOINT", "").strip()
REDIS_HOST    = ELASTICACHE_PRIMARY_ENDPOINT or os.getenv("REDIS_HOST", "127.0.0.1")
REDIS_PORT    = int(os.getenv("REDIS_PORT", os.getenv("ELASTICACHE_PORT", "6379")))


def _get_int(name, default, minimum=0):
    raw = os.getenv(name)
    if raw is None or str(raw).strip() == "":
        return max(minimum, default)
    try:
        return max(minimum, int(str(raw).strip(), 10))
    except ValueError:
        return max(minimum, default)


def _get_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    s = str(raw).strip().lower()
    if s in ("1", "true", "t", "yes", "y", "on"):
        return True
    if s in ("0", "false", "f", "no", "n", "off"):
        return False
    return default


# ticketing-was/config.py 와 동일 규칙: SQS URL 이 있으면 예매 상태 ElastiCache 필수 → 자동 True
BOOKING_STATE_ENABLED = _get_bool("BOOKING_STATE_ENABLED", True)
if SQS_QUEUE_URL:
    BOOKING_STATE_ENABLED = True

# read-api 와 동일: 조회 캐시 무효화만 noop (연결 생략)
CACHE_ENABLED = _get_bool("CACHE_ENABLED", True)

REDIS_MAX_CONNECTIONS = _get_int("REDIS_MAX_CONNECTIONS", 50, 1)
REDIS_SOCKET_TIMEOUT_SEC = _get_int("REDIS_SOCKET_TIMEOUT_SEC", 5, 0)
REDIS_CONNECT_TIMEOUT_SEC = _get_int("REDIS_CONNECT_TIMEOUT_SEC", 3, 0)
REDIS_HEALTH_CHECK_INTERVAL_SEC = _get_int("REDIS_HEALTH_CHECK_INTERVAL_SEC", 30, 0)

# ticketing-was/theater/theaters_read.py 와 동일해야 함
THEATERS_BOOTSTRAP_CACHE_KEY = "theaters:booking:bootstrap:v6"


def _theaters_detail_cache_key(theater_id: int) -> str:
    return f"theaters:booking:detail:{int(theater_id)}:v6"


_pool_kw = {
    "host": REDIS_HOST,
    "port": REDIS_PORT,
    "decode_responses": True,
    "max_connections": REDIS_MAX_CONNECTIONS,
}
if REDIS_CONNECT_TIMEOUT_SEC > 0:
    _pool_kw["socket_connect_timeout"] = REDIS_CONNECT_TIMEOUT_SEC
if REDIS_SOCKET_TIMEOUT_SEC > 0:
    _pool_kw["socket_timeout"] = REDIS_SOCKET_TIMEOUT_SEC
if REDIS_HEALTH_CHECK_INTERVAL_SEC > 0:
    _pool_kw["health_check_interval"] = REDIS_HEALTH_CHECK_INTERVAL_SEC

ELASTICACHE_LOGICAL_DB_CACHE = min(15, _get_int("ELASTICACHE_LOGICAL_DB_CACHE", 0, 0))
ELASTICACHE_LOGICAL_DB_BOOKING = min(15, _get_int("ELASTICACHE_LOGICAL_DB_BOOKING", 1, 0))
if ELASTICACHE_LOGICAL_DB_BOOKING == ELASTICACHE_LOGICAL_DB_CACHE:
    ELASTICACHE_LOGICAL_DB_BOOKING = (ELASTICACHE_LOGICAL_DB_CACHE + 1) % 16

_cache_pool_kw = {**_pool_kw, "db": ELASTICACHE_LOGICAL_DB_CACHE}
_booking_pool_kw = {**_pool_kw, "db": ELASTICACHE_LOGICAL_DB_BOOKING}


class _NoopBookingRedis:
    def get(self, key):
        return None

    def setex(self, key, ttl_seconds, value):
        return True

    def delete(self, *keys):
        return 0


class _NoopCacheRedis:
    def delete(self, *keys):
        return 0


if CACHE_ENABLED:
    elasticache_read_cache_client = redis.Redis(
        connection_pool=redis.ConnectionPool(**_cache_pool_kw)
    )
else:
    elasticache_read_cache_client = _NoopCacheRedis()

if BOOKING_STATE_ENABLED:
    elasticache_booking_client = redis.Redis(
        connection_pool=redis.ConnectionPool(**_booking_pool_kw)
    )
else:
    elasticache_booking_client = _NoopBookingRedis()

SQS_RECEIVE_MAX_MESSAGES = min(10, max(1, _get_int("SQS_RECEIVE_MAX_MESSAGES", 5, 1)))
# 한 번 Receive로 온 메시지(서로 다른 FIFO 그룹)를 동시에 처리. 1이면 기존과 같이 순차.
WORKER_SQS_BATCH_CONCURRENCY = min(10, max(1, _get_int("WORKER_SQS_BATCH_CONCURRENCY", 10, 1)))
SQS_WAIT_TIME_SECONDS = min(20, max(0, _get_int("SQS_WAIT_TIME_SECONDS", 20, 0)))
SQS_POLL_ERROR_BACKOFF_SEC = max(1, _get_int("SQS_POLL_ERROR_BACKOFF_SEC", 3, 1))
SQS_BOTO_MAX_ATTEMPTS = _get_int("SQS_BOTO_MAX_ATTEMPTS", 5, 1)
_sqs_retry_mode = os.getenv("SQS_BOTO_RETRY_MODE", "adaptive").strip().lower()
if _sqs_retry_mode not in ("standard", "adaptive"):
    _sqs_retry_mode = "standard"
_sqs_connect = max(1, _get_int("SQS_CONNECT_TIMEOUT_SEC", 5, 1))
_sqs_read = max(1, _get_int("SQS_READ_TIMEOUT_SEC", 30, 1))

_sqs_config = Config(
    retries={"max_attempts": SQS_BOTO_MAX_ATTEMPTS, "mode": _sqs_retry_mode},
    connect_timeout=_sqs_connect,
    read_timeout=_sqs_read,
)
sqs = boto3.client("sqs", region_name=AWS_REGION, config=_sqs_config)


def get_tx_conn():
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor, autocommit=False,
    )


def _to_int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _parse_seat_key(value):
    parts = str(value or "").strip().split("-")
    if len(parts) != 2:
        return None
    r, c = _to_int(parts[0]), _to_int(parts[1])
    return (r, c) if r > 0 and c > 0 else None


def _generate_booking_code():
    import secrets, string
    letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(2))
    digits = "".join(secrets.choice(string.digits) for _ in range(6))
    return f"{letters}{digits}"


def _booking_result_key(booking_ref: str) -> str:
    return f"booking:result:{booking_ref}"


def _booking_queued_key(booking_ref: str) -> str:
    """write-api sqs_client._booking_queued_key 과 동일한 규약."""
    return f"booking:queued:{booking_ref}"


def store_result(booking_ref, result):
    """ElastiCache booking 논리 DB에 결과 저장(write-api 폴링). 완료 시 queued 제거."""
    key = _booking_result_key(booking_ref)
    elasticache_booking_client.setex(key, 600, json.dumps(result, default=str))
    try:
        elasticache_booking_client.delete(_booking_queued_key(booking_ref))
    except Exception:
        log.debug("booking queued 키 삭제 실패(무시)", exc_info=True)
    log.info("결과 저장: %s", key)


def _handle_one_sqs_message(msg: dict) -> bool:
    """
    True  → 처리 완료(또는 이미 처리된 중복)로 메시지 삭제(ACK)해도 됨.
    False → 삭제하지 않음 → 가시성 타임아웃 후 재전달 → maxReceiveCount 초과 시 DLQ.
    """
    receipt = msg.get("ReceiptHandle")
    if not receipt:
        log.warning("SQS 메시지에 ReceiptHandle 없음")
        return False

    attrs = msg.get("Attributes") or {}
    try:
        rc = int(attrs.get("ApproximateReceiveCount", "1"))
    except (TypeError, ValueError):
        rc = 1
    if rc >= 2:
        log.warning(
            "SQS 재전달 수신 ApproximateReceiveCount=%s MessageId=%s",
            rc,
            msg.get("MessageId"),
        )

    try:
        body = json.loads(msg["Body"])
    except (KeyError, TypeError, json.JSONDecodeError):
        log.exception("SQS 메시지 Body JSON 파싱 실패 MessageId=%s", msg.get("MessageId"))
        return False

    ref = body.get("booking_ref")
    if isinstance(ref, str) and ref:
        try:
            if elasticache_booking_client.get(_booking_result_key(ref)):
                log.info("이미 결과가 있는 booking_ref=%s — 중복 전달 ACK", ref)
                return True
        except Exception:
            log.exception("Redis 중복 확인 실패 — 처리 진행")

    try:
        booking_type = body.get("booking_type", "theater")
        if booking_type == "concert":
            process_concert_booking(body)
        else:
            process_theater_booking(body)
        return True
    except Exception:
        log.exception("예매 핸들러 실패 MessageId=%s ref=%s", msg.get("MessageId"), ref)
        return False


def _delete_message(receipt_handle: str) -> None:
    sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)


# ── 극장 예매 처리 ────────────────────────────────────────────────────────────
def process_theater_booking(body):
    booking_ref = body["booking_ref"]
    user_id = _to_int(body["user_id"])
    schedule_id = _to_int(body["schedule_id"])
    seats = body.get("seats") or []

    parsed_seats = [_parse_seat_key(s) for s in seats]
    parsed_seats = [s for s in parsed_seats if s]
    req_count = len(parsed_seats)

    theater_id_for_cache = 0
    committed_ok = False
    conn = get_tx_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT s.schedule_id, s.hall_id, h.theater_id, s.total_count, s.remain_count "
                "FROM schedules s "
                "INNER JOIN halls h ON h.hall_id = s.hall_id "
                "WHERE s.schedule_id = %s FOR UPDATE",
                (schedule_id,),
            )
            schedule = cur.fetchone()
            if not schedule:
                store_result(booking_ref, {"ok": False, "code": "NOT_FOUND"})
                return

            theater_id_for_cache = _to_int(schedule.get("theater_id"))
            hall_id = _to_int(schedule.get("hall_id"))

            seat_ids = []
            for row_no, col_no in parsed_seats:
                cur.execute(
                    "SELECT seat_id FROM hall_seats "
                    "WHERE hall_id = %s AND seat_row_no = %s AND seat_col_no = %s",
                    (hall_id, row_no, col_no),
                )
                seat_row = cur.fetchone()
                if not seat_row:
                    conn.rollback()
                    store_result(booking_ref, {"ok": False, "code": "INVALID_SEAT"})
                    return
                seat_ids.append(_to_int(seat_row.get("seat_id")))

            cur.execute(
                "UPDATE schedules SET remain_count = remain_count - %s "
                "WHERE schedule_id = %s AND remain_count >= %s",
                (req_count, schedule_id, req_count),
            )
            if cur.rowcount != 1:
                conn.rollback()
                store_result(booking_ref, {"ok": False, "code": "SOLD_OUT"})
                return

            cur.execute(
                "INSERT INTO booking (user_id, schedule_id, reg_count, book_status) "
                "VALUES (%s, %s, %s, 'PAID')",
                (user_id, schedule_id, req_count),
            )
            booking_id = cur.lastrowid

            booking_code = ""
            for _ in range(12):
                code = _generate_booking_code()
                try:
                    cur.execute("UPDATE booking SET booking_code = %s WHERE booking_id = %s", (code, booking_id))
                    booking_code = code
                    break
                except pymysql.err.IntegrityError:
                    continue

            for seat_id in seat_ids:
                cur.execute(
                    "INSERT INTO booking_seats (booking_id, schedule_id, seat_id) "
                    "VALUES (%s, %s, %s)",
                    (booking_id, schedule_id, seat_id),
                )

            cur.execute(
                "INSERT INTO payment (booking_id, pay_yn, paid_at) "
                "VALUES (%s, 'Y', NOW())",
                (booking_id,),
            )
            payment_id = cur.lastrowid

            cur.execute("SELECT remain_count FROM schedules WHERE schedule_id = %s", (schedule_id,))
            remain = cur.fetchone()
            remain_count_after = _to_int(remain.get("remain_count") if remain else 0)

            if remain_count_after <= 0:
                cur.execute("UPDATE schedules SET status = 'CLOSED' WHERE schedule_id = %s", (schedule_id,))

        conn.commit()
        committed_ok = True
        store_result(booking_ref, {
            "ok": True, "code": "OK",
            "booking_id": booking_id, "booking_code": booking_code,
            "payment_id": payment_id, "remain_count_after": remain_count_after,
        })

    except pymysql.err.IntegrityError:
        conn.rollback()
        store_result(booking_ref, {"ok": False, "code": "DUPLICATE_SEAT"})
    except Exception as e:
        conn.rollback()
        store_result(booking_ref, {"ok": False, "code": "ERROR", "message": str(e)})
        log.error("극장 예매 처리 실패: %s", e)
    finally:
        conn.close()

    # 극장 read 캐시: 부트스트랩 1키에 전 스케줄 잔여가 들 있음 → 성공 시 항상 무효화.
    # (theater_id 가 0이면 예전 코드는 부트스트랩도 안 지워 UI가 30/30에 고정되는 경우가 있음)
    if committed_ok:
        try:
            keys = [THEATERS_BOOTSTRAP_CACHE_KEY]
            if theater_id_for_cache > 0:
                keys.append(_theaters_detail_cache_key(theater_id_for_cache))
            elasticache_read_cache_client.delete(*keys)
        except Exception:
            pass


# ── 콘서트 예매 처리 ─────────────────────────────────────────────────────────
def process_concert_booking(body):
    booking_ref = body["booking_ref"]
    user_id = _to_int(body["user_id"])
    show_id = _to_int(body["show_id"])
    seats = body.get("seats") or []

    parsed_seats = [_parse_seat_key(s) for s in seats]
    parsed_seats = [s for s in parsed_seats if s]
    req_count = len(parsed_seats)

    conn = get_tx_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT show_id, concert_id, seat_rows, seat_cols, "
                "total_count, remain_count, status "
                "FROM concert_shows WHERE show_id = %s FOR UPDATE",
                (show_id,),
            )
            show = cur.fetchone()
            if not show:
                conn.rollback()
                store_result(booking_ref, {"ok": False, "code": "NOT_FOUND"})
                return

            seat_rows = _to_int(show.get("seat_rows"))
            seat_cols = _to_int(show.get("seat_cols"))

            for row_no, col_no in parsed_seats:
                if row_no > seat_rows or col_no > seat_cols:
                    conn.rollback()
                    store_result(booking_ref, {"ok": False, "code": "INVALID_SEAT"})
                    return

            cur.execute(
                "UPDATE concert_shows SET remain_count = remain_count - %s "
                "WHERE show_id = %s AND remain_count >= %s "
                "AND UPPER(COALESCE(status, '')) = 'OPEN'",
                (req_count, show_id, req_count),
            )
            if cur.rowcount != 1:
                conn.rollback()
                store_result(booking_ref, {"ok": False, "code": "SOLD_OUT"})
                return

            cur.execute(
                "INSERT INTO concert_booking (user_id, show_id, reg_count, book_status) "
                "VALUES (%s, %s, %s, 'PAID')",
                (user_id, show_id, req_count),
            )
            booking_id = cur.lastrowid

            import secrets, string
            booking_code = ""
            for _ in range(12):
                letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(2))
                digits = "".join(secrets.choice(string.digits) for _ in range(6))
                code = f"C{letters}{digits}"
                try:
                    cur.execute("UPDATE concert_booking SET booking_code = %s WHERE booking_id = %s", (code, booking_id))
                    booking_code = code
                    break
                except pymysql.err.IntegrityError:
                    continue

            for row_no, col_no in parsed_seats:
                cur.execute(
                    "INSERT INTO concert_booking_seats "
                    "(booking_id, show_id, seat_row_no, seat_col_no) "
                    "VALUES (%s, %s, %s, %s)",
                    (booking_id, show_id, row_no, col_no),
                )

            cur.execute(
                "INSERT INTO concert_payment (booking_id, pay_yn, paid_at) "
                "VALUES (%s, 'Y', NOW())",
                (booking_id,),
            )
            payment_id = cur.lastrowid

            cur.execute("SELECT remain_count FROM concert_shows WHERE show_id = %s", (show_id,))
            remain_row = cur.fetchone()
            remain_count_after = _to_int(remain_row.get("remain_count") if remain_row else 0)

            if remain_count_after <= 0:
                cur.execute("UPDATE concert_shows SET status = 'CLOSED' WHERE show_id = %s", (show_id,))

        conn.commit()
        store_result(booking_ref, {
            "ok": True, "code": "OK",
            "booking_id": booking_id, "booking_code": booking_code,
            "payment_id": payment_id, "remain_count_after": remain_count_after,
        })

        # 콘서트: 회차 스냅샷(+레거시 부트스트랩)만 무효화. 목록/공연상세는 매 티켓마다 지우지 않음.
        try:
            cid = _to_int(show.get("concert_id"))
            if cid > 0 and show_id > 0:
                elasticache_read_cache_client.delete(
                    f"concert:bootstrap:{cid}:read:v1",
                    f"concert:show:{show_id}:read:v2",
                )
        except Exception:
            pass

    except pymysql.err.IntegrityError:
        conn.rollback()
        store_result(booking_ref, {"ok": False, "code": "DUPLICATE_SEAT"})
    except Exception as e:
        conn.rollback()
        store_result(booking_ref, {"ok": False, "code": "ERROR", "message": str(e)})
        log.error("콘서트 예매 처리 실패: %s", e)
    finally:
        conn.close()


# ── SQS 폴링 루프 ────────────────────────────────────────────────────────────
def _process_received_batch(messages: list) -> None:
    """배치 내 메시지는 서로 다른 MessageGroupId일 수 있어 병렬 처리해도 FIFO 순서를 깨지 않음."""
    if not messages:
        return

    def _ack_if_ok(msg: dict, ok: bool) -> None:
        receipt = msg.get("ReceiptHandle")
        if ok and receipt:
            try:
                _delete_message(receipt)
            except Exception:
                log.exception(
                    "SQS delete_message 실패 (메시지가 재전달될 수 있음) id=%s",
                    msg.get("MessageId"),
                )

    if len(messages) <= 1 or WORKER_SQS_BATCH_CONCURRENCY <= 1:
        for msg in messages:
            _ack_if_ok(msg, _handle_one_sqs_message(msg))
        return

    workers = min(len(messages), WORKER_SQS_BATCH_CONCURRENCY)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        future_to_msg = {pool.submit(_handle_one_sqs_message, msg): msg for msg in messages}
        for fut in as_completed(future_to_msg):
            msg = future_to_msg[fut]
            try:
                ok = fut.result()
            except Exception:
                log.exception(
                    "워커 배치 처리 예외 MessageId=%s",
                    msg.get("MessageId"),
                )
                ok = False
            _ack_if_ok(msg, ok)


def poll_loop():
    log.info(
        "worker-svc 시작 — SQS url=%s max_msg=%s batch_workers=%s wait=%ss | "
        "ElastiCache cache_db=%s booking_db=%s CACHE_ENABLED=%s BOOKING_STATE_ENABLED=%s",
        SQS_QUEUE_URL,
        SQS_RECEIVE_MAX_MESSAGES,
        WORKER_SQS_BATCH_CONCURRENCY,
        SQS_WAIT_TIME_SECONDS,
        ELASTICACHE_LOGICAL_DB_CACHE,
        ELASTICACHE_LOGICAL_DB_BOOKING,
        CACHE_ENABLED,
        BOOKING_STATE_ENABLED,
    )
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=SQS_RECEIVE_MAX_MESSAGES,
                WaitTimeSeconds=SQS_WAIT_TIME_SECONDS,
                AttributeNames=["ApproximateReceiveCount", "SentTimestamp"],
            )
            messages = resp.get("Messages") or []
            _process_received_batch(messages)
        except Exception as e:
            log.error("SQS 폴링 오류: %s", e)
            time.sleep(SQS_POLL_ERROR_BACKOFF_SEC)


# ── FastAPI (헬스체크 + 메트릭) ───────────────────────────────────────────────
from fastapi import FastAPI
from contextlib import asynccontextmanager
import threading


@asynccontextmanager
async def lifespan(app):
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok", "service": "worker-svc"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "5002")))
