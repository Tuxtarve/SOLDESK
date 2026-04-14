"""
SQS FIFO Worker — 예매 메시지 처리.
theaters_write._commit_booking_sync / concert_write._commit_concert_booking_sync 로직을 재사용.

중요(콘서트):
- 기존에는 concert_shows 1행을 `FOR UPDATE`로 잠가 동일 회차(show_id)를 사실상 직렬 처리했다.
- 콘서트 티켓팅의 동시성 단위는 "회차 전체"가 아니라 "좌석"이므로,
  `concert_booking_seats`의 ACTIVE 유니크 인덱스(show_id,row,col)를 락 단위로 사용한다.
  → 회차는 1개여도 서로 다른 좌석은 병렬로 처리 가능(파드/스레드 확장 효과가 보임).
"""
import os
import json
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
import redis
import pymysql
import time
import threading
from botocore.config import Config
from fastapi.responses import PlainTextResponse


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

# booking:result TTL(초) — 큐 적체/지연이 길 때도 결과 조회가 가능하도록 기본을 넉넉히 둔다.
BOOKING_RESULT_TTL_SEC = _get_int("BOOKING_RESULT_TTL_SEC", 3600, 60)


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

SQS_RECEIVE_MAX_MESSAGES = min(10, max(1, _get_int("SQS_RECEIVE_MAX_MESSAGES", 10, 1)))
# 한 번 Receive로 온 메시지(서로 다른 FIFO 그룹)를 동시에 처리. 1이면 기존과 같이 순차.
# (데모/부하 환경에서는 20~50까지도 유효. 단, DB 동시성 제한(WORKER_DB_MAX_CONCURRENT)과 함께 올릴 것.)
WORKER_SQS_BATCH_CONCURRENCY = min(50, max(1, _get_int("WORKER_SQS_BATCH_CONCURRENCY", 20, 1)))
# 폴링 루프 스레드 수(파드당). FIFO 샤딩 + 다수 poller 조합이 burst 처리량을 크게 끌어올린다.
WORKER_SQS_POLLERS = min(10, max(1, _get_int("WORKER_SQS_POLLERS", 2, 1)))
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

# 파드당 DB 동시 실행 제한(과도한 커넥션/락 경합으로 전체 처리량이 떨어지는 것을 방지).
# 값이 크면 DB 부하가 커지고, KEDA 데모에서는 처리량 증가가 더 선명해진다(단 RDS 한도 주의).
_db_max_conc_default = max(1, min(200, WORKER_SQS_BATCH_CONCURRENCY * WORKER_SQS_POLLERS))
WORKER_DB_MAX_CONCURRENT = max(
    1,
    min(
        200,
        _get_int("WORKER_DB_MAX_CONCURRENT", _db_max_conc_default, 1),
    ),
)
_db_sem = threading.Semaphore(WORKER_DB_MAX_CONCURRENT)

# 배치 처리 스레드풀은 재사용(배치마다 생성/파괴하지 않음).
_batch_pool = ThreadPoolExecutor(max_workers=WORKER_SQS_BATCH_CONCURRENCY)


class _Stats:
    def __init__(self):
        self._lock = threading.Lock()
        self.started_at = time.time()
        self.received = 0
        self.acked = 0
        self.process_ok = 0
        self.process_fail = 0
        self.db_sem_wait_ms_sum = 0.0
        self.db_sem_wait_ms_max = 0.0
        self.handle_ms_sum = 0.0
        self.handle_ms_max = 0.0
        self.last_error = ""

    def inc_received(self, n: int):
        with self._lock:
            self.received += int(n)

    def inc_acked(self):
        with self._lock:
            self.acked += 1

    def record_ok(self, handle_ms: float, sem_wait_ms: float):
        with self._lock:
            self.process_ok += 1
            self.handle_ms_sum += handle_ms
            self.handle_ms_max = max(self.handle_ms_max, handle_ms)
            self.db_sem_wait_ms_sum += sem_wait_ms
            self.db_sem_wait_ms_max = max(self.db_sem_wait_ms_max, sem_wait_ms)

    def record_fail(self, handle_ms: float, sem_wait_ms: float, err: str):
        with self._lock:
            self.process_fail += 1
            self.handle_ms_sum += handle_ms
            self.handle_ms_max = max(self.handle_ms_max, handle_ms)
            self.db_sem_wait_ms_sum += sem_wait_ms
            self.db_sem_wait_ms_max = max(self.db_sem_wait_ms_max, sem_wait_ms)
            self.last_error = (err or "")[:500]

    def snapshot(self) -> dict:
        with self._lock:
            total = self.process_ok + self.process_fail
            avg_handle = (self.handle_ms_sum / total) if total else 0.0
            avg_sem = (self.db_sem_wait_ms_sum / total) if total else 0.0
            return {
                "started_at": self.started_at,
                "uptime_sec": max(0.0, time.time() - self.started_at),
                "sqs": {
                    "received": self.received,
                    "acked": self.acked,
                    "inflight_est": max(0, self.received - self.acked),
                },
                "process": {
                    "ok": self.process_ok,
                    "fail": self.process_fail,
                    "avg_handle_ms": round(avg_handle, 3),
                    "max_handle_ms": round(self.handle_ms_max, 3),
                    "avg_db_sem_wait_ms": round(avg_sem, 3),
                    "max_db_sem_wait_ms": round(self.db_sem_wait_ms_max, 3),
                    "last_error": self.last_error,
                },
                "config": {
                    "max_messages": SQS_RECEIVE_MAX_MESSAGES,
                    "batch_concurrency": WORKER_SQS_BATCH_CONCURRENCY,
                    "pollers": WORKER_SQS_POLLERS,
                    "db_max_concurrent": WORKER_DB_MAX_CONCURRENT,
                    "wait_time_sec": SQS_WAIT_TIME_SECONDS,
                },
            }


_stats = _Stats()


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
    elasticache_booking_client.setex(key, int(BOOKING_RESULT_TTL_SEC), json.dumps(result, default=str))
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

    t0 = time.monotonic()
    sem_wait_ms = 0.0
    try:
        booking_type = body.get("booking_type", "theater")
        t_sem = time.monotonic()
        with _db_sem:
            sem_wait_ms = (time.monotonic() - t_sem) * 1000.0
            if booking_type == "concert":
                process_concert_booking(body)
            else:
                process_theater_booking(body)
        _stats.record_ok((time.monotonic() - t0) * 1000.0, sem_wait_ms)
        return True
    except Exception as e:
        _stats.record_fail((time.monotonic() - t0) * 1000.0, sem_wait_ms, str(e))
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
                "FROM concert_shows WHERE show_id = %s",
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

            # 좌석 점유(동시성 제어의 핵심): ACTIVE 유니크 인덱스가 좌석 단위로 경쟁을 해결한다.
            # 다건 좌석은 멀티 VALUES로 한 번에 INSERT해 round-trip을 줄인다.
            values_sql = ",".join(["(%s,%s,%s,%s)"] * len(parsed_seats))
            params = []
            for row_no, col_no in parsed_seats:
                params.extend([booking_id, show_id, row_no, col_no])
            cur.execute(
                "INSERT INTO concert_booking_seats (booking_id, show_id, seat_row_no, seat_col_no) "
                f"VALUES {values_sql}",
                tuple(params),
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

            # remain_count/status는 동시성 경로에서 더 이상 강하게 유지하지 않는다.
            # UI/조회는 show 스냅샷에서 reserved_seats 수로 remain을 유도하도록(read-cache) 맞춘다.

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
                _stats.inc_acked()
            except Exception:
                log.exception(
                    "SQS delete_message 실패 (메시지가 재전달될 수 있음) id=%s",
                    msg.get("MessageId"),
                )

    if len(messages) <= 1 or WORKER_SQS_BATCH_CONCURRENCY <= 1:
        for msg in messages:
            _ack_if_ok(msg, _handle_one_sqs_message(msg))
        return

    # 전역 스레드풀에서 처리(배치별 생성 비용 제거). workers 제한은 submit 수로 자연 제한됨.
    future_to_msg = {_batch_pool.submit(_handle_one_sqs_message, msg): msg for msg in messages}
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


def poll_loop(poller_id: int = 0):
    log.info(
        "worker-svc 시작(poller=%s) — SQS url=%s max_msg=%s batch_workers=%s pollers=%s db_max_conc=%s wait=%ss | "
        "ElastiCache cache_db=%s booking_db=%s CACHE_ENABLED=%s BOOKING_STATE_ENABLED=%s",
        poller_id,
        SQS_QUEUE_URL,
        SQS_RECEIVE_MAX_MESSAGES,
        WORKER_SQS_BATCH_CONCURRENCY,
        WORKER_SQS_POLLERS,
        WORKER_DB_MAX_CONCURRENT,
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
            if messages:
                _stats.inc_received(len(messages))
            _process_received_batch(messages)
        except Exception as e:
            _stats.record_fail(0.0, 0.0, str(e))
            log.error("SQS 폴링 오류: %s", e)
            time.sleep(SQS_POLL_ERROR_BACKOFF_SEC)


# ── FastAPI (헬스체크 + 메트릭) ───────────────────────────────────────────────
from fastapi import FastAPI
from contextlib import asynccontextmanager
import threading


@asynccontextmanager
async def lifespan(app):
    threads = []
    for i in range(WORKER_SQS_POLLERS):
        t = threading.Thread(target=poll_loop, args=(i,), daemon=True)
        t.start()
        threads.append(t)
    yield


app = FastAPI(lifespan=lifespan)


# ✅ 헬스 체크 (서비스 정상 여부 확인)
@app.get("/health")
def health():
    data = _stats.snapshot()
    return {
        "status": "ok",
        "service": "worker-svc",
        "uptime_sec": data["uptime_sec"]  # 서비스 실행 시간
    }


# ✅ readiness 체크 (K8s에서 트래픽 받을 준비 여부 판단)
@app.get("/ready")
def ready():
    if not SQS_QUEUE_URL:
        return {"status": "fail", "reason": "SQS 설정 안됨"}
    return {"status": "ready"}


# ✅ Prometheus 메트릭 (핵심🔥)
@app.get("/metrics")
def metrics():
    data = _stats.snapshot()

    return PlainTextResponse(
"""# HELP worker_processed_ok 성공적으로 처리된 메시지 총 개수
# TYPE worker_processed_ok counter
worker_processed_ok {data['process']['ok']}

# HELP worker_processed_fail 처리 실패한 메시지 총 개수
# TYPE worker_processed_fail counter
worker_processed_fail {data['process']['fail']}

# HELP worker_inflight_messages 현재 처리 중인 메시지 수
# TYPE worker_inflight_messages gauge
worker_inflight_messages {data['sqs']['inflight_est']}

# HELP worker_sqs_received_total SQS에서 받은 총 메시지 수
# TYPE worker_sqs_received_total counter
worker_sqs_received_total {data['sqs']['received']}

# HELP worker_sqs_acked_total 처리 완료 후 ACK된 메시지 수
# TYPE worker_sqs_acked_total counter
worker_sqs_acked_total {data['sqs']['acked']}

# HELP worker_handle_latency_ms 평균 처리 시간(ms)
# TYPE worker_handle_latency_ms gauge
worker_handle_latency_ms {data['process']['avg_handle_ms']}

# HELP worker_db_wait_ms DB 세마포어 대기 평균 시간(ms)
# TYPE worker_db_wait_ms gauge
worker_db_wait_ms {data['process']['avg_db_sem_wait_ms']}
"""
)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "5002")))