import os
import json
import uuid
import hashlib
import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from fastapi import FastAPI, Request, Response
from contextlib import asynccontextmanager
import aiomysql
import redis.asyncio as aioredis
import boto3
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST, REGISTRY
from prometheus_fastapi_instrumentator import Instrumentator

# ── 로깅 ──────────────────────────────────────────────────────────────────────
logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("reserv-svc")

# ── Prometheus 메트릭 ─────────────────────────────────────────────────────────
reservation_total = Counter(
    "reservation_requests_total", "예매 요청 총 수", ["status"],
)
reservation_duration = Histogram(
    "reservation_duration_ms", "예매 처리 시간 (ms)",
    buckets=[10, 30, 50, 100, 300, 500],
)
seat_available = Gauge(
    "seat_available_count", "이벤트별 잔여 좌석", ["event_id"],
)

# ── AWS SQS ───────────────────────────────────────────────────────────────────
REGION = os.getenv("AWS_REGION", "ap-northeast-2")
SQS_URL = os.getenv("SQS_QUEUE_URL")
sqs_client = boto3.client("sqs", region_name=REGION)

# ── 전역 풀 ───────────────────────────────────────────────────────────────────
writer_pool: aiomysql.Pool | None = None
reader_pool: aiomysql.Pool | None = None
redis_client: aioredis.Redis | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global writer_pool, reader_pool, redis_client

    db_common = dict(
        user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""),
        db=os.getenv("DB_NAME", "ticketing"),
        port=int(os.getenv("DB_PORT", "3306")),
        maxsize=5,
        autocommit=True,
    )
    writer_pool = await aiomysql.create_pool(host=os.getenv("DB_WRITER_HOST", "127.0.0.1"), **db_common)
    reader_pool = await aiomysql.create_pool(host=os.getenv("DB_READER_HOST", "127.0.0.1"), **db_common)
    redis_client = aioredis.Redis(
        host=os.getenv("REDIS_HOST", "127.0.0.1"),
        port=int(os.getenv("REDIS_PORT", "6379")),
        decode_responses=True,
    )
    # Redis 좌석 재고 초기화 (DB 기준)
    async with reader_pool.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                "SELECT event_id, COUNT(*) AS cnt FROM seats "
                "WHERE status = 'AVAILABLE' GROUP BY event_id"
            )
            for row in await cur.fetchall():
                key = f"seat:available:{row['event_id']}"
                await redis_client.set(key, row["cnt"])
                seat_available.labels(event_id=row["event_id"]).set(row["cnt"])
                log.info("Redis 좌석 재고 초기화: %s = %s", key, row["cnt"])

    log.info("reserv-svc 시작, port=%s", os.getenv("PORT", "3001"))
    yield

    if redis_client:
        await redis_client.close()
    if writer_pool:
        writer_pool.close()
        await writer_pool.wait_closed()
    if reader_pool:
        reader_pool.close()
        await reader_pool.wait_closed()


app = FastAPI(lifespan=lifespan)


# ── 헬스체크 ──────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "service": "reserv-svc"}


# ── 예매 생성 (핵심 로직) ─────────────────────────────────────────────────────
@app.post("/api/reservations")
async def create_reservation(request: Request):
    import time
    start = time.time()

    body = await request.json()
    event_id = body.get("eventId")
    seat_ids = body.get("seatIds")
    user_id = request.headers.get("x-amzn-oidc-identity") or body.get("userId")

    if not user_id or not event_id or not seat_ids:
        reservation_total.labels(status="bad_request").inc()
        return Response(
            content=json.dumps({"error": "필수 파라미터 누락"}),
            status_code=400,
            media_type="application/json",
        )

    seat_ids_sorted = sorted(seat_ids)
    lock_key = f"seat:lock:{event_id}:{','.join(seat_ids_sorted)}"
    avail_key = f"seat:available:{event_id}"

    try:
        # Redis 분산 락 (NX = 없을 때만 SET)
        locked = await redis_client.set(lock_key, user_id, ex=600, nx=True)
        if not locked:
            reservation_total.labels(status="seat_locked").inc()
            elapsed = (time.time() - start) * 1000
            reservation_duration.observe(elapsed)
            return Response(
                content=json.dumps({"error": "다른 사용자가 선택 중인 좌석입니다"}),
                status_code=409,
                media_type="application/json",
            )

        # Redis 재고 차감
        remaining = await redis_client.decrby(avail_key, len(seat_ids))
        if remaining < 0:
            await redis_client.incrby(avail_key, len(seat_ids))
            await redis_client.delete(lock_key)
            reservation_total.labels(status="sold_out").inc()
            elapsed = (time.time() - start) * 1000
            reservation_duration.observe(elapsed)
            return Response(
                content=json.dumps({"error": "잔여 좌석이 부족합니다"}),
                status_code=409,
                media_type="application/json",
            )

        seat_available.labels(event_id=event_id).set(remaining)

        reservation_id = str(uuid.uuid4())
        raw_key = f"{user_id}:{event_id}:{','.join(seat_ids_sorted)}"
        idempotency_key = hashlib.sha256(raw_key.encode()).hexdigest()
        expires_at = (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()

        # SQS FIFO 큐에 비동기 처리 위임
        sqs_client.send_message(
            QueueUrl=SQS_URL,
            MessageGroupId=event_id,
            MessageDeduplicationId=idempotency_key,
            MessageBody=json.dumps({
                "reservationId": reservation_id,
                "userId": user_id,
                "eventId": event_id,
                "seatIds": seat_ids,
                "expiresAt": expires_at,
                "lockKey": lock_key,
            }),
        )

        reservation_total.labels(status="pending").inc()
        elapsed = (time.time() - start) * 1000
        reservation_duration.observe(elapsed)
        log.info("예매 큐 투입: reservationId=%s, eventId=%s", reservation_id, event_id)

        return Response(
            content=json.dumps({
                "status": "PENDING",
                "reservationId": reservation_id,
                "expiresAt": expires_at,
                "message": "예매 접수 완료. 10분 내 결제를 완료해 주세요.",
            }),
            status_code=202,
            media_type="application/json",
        )

    except Exception as e:
        await redis_client.delete(lock_key)
        await redis_client.incrby(avail_key, len(seat_ids))
        reservation_total.labels(status="error").inc()
        elapsed = (time.time() - start) * 1000
        reservation_duration.observe(elapsed)
        log.error("예매 처리 실패: %s", e)
        return Response(
            content=json.dumps({"error": "예매 처리 중 오류가 발생했습니다"}),
            status_code=500,
            media_type="application/json",
        )


# ── 예매 조회 ─────────────────────────────────────────────────────────────────
@app.get("/api/reservations/{reservation_id}")
async def get_reservation(reservation_id: str, request: Request):
    user_id = request.headers.get("x-amzn-oidc-identity")
    try:
        async with reader_pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT r.*, GROUP_CONCAT(rs.seat_id) AS seat_ids "
                    "FROM reservations r "
                    "LEFT JOIN reservation_seats rs ON r.id = rs.reservation_id "
                    "WHERE r.id = %s AND r.user_id = %s "
                    "GROUP BY r.id",
                    (reservation_id, user_id),
                )
                row = await cur.fetchone()

        if not row:
            return Response(
                content=json.dumps({"error": "예매를 찾을 수 없습니다"}),
                status_code=404,
                media_type="application/json",
            )

        for k, v in row.items():
            if hasattr(v, "isoformat"):
                row[k] = v.isoformat()
            elif isinstance(v, Decimal):
                row[k] = float(v)
        return row
    except Exception as e:
        return Response(
            content=json.dumps({"error": "서버 오류"}),
            status_code=500,
            media_type="application/json",
        )


# ── 내 예매 목록 ──────────────────────────────────────────────────────────────
@app.get("/api/reservations")
async def list_reservations(request: Request):
    user_id = request.headers.get("x-amzn-oidc-identity")
    if not user_id:
        return Response(
            content=json.dumps({"error": "인증 필요"}),
            status_code=401,
            media_type="application/json",
        )
    try:
        async with reader_pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT r.id, r.status, r.total_price, r.created_at, r.expires_at, "
                    "e.title AS event_title, e.start_at "
                    "FROM reservations r "
                    "JOIN events e ON r.event_id = e.id "
                    "WHERE r.user_id = %s AND r.status != 'EXPIRED' "
                    "ORDER BY r.created_at DESC LIMIT 20",
                    (user_id,),
                )
                rows = await cur.fetchall()

        for row in rows:
            for k, v in row.items():
                if hasattr(v, "isoformat"):
                    row[k] = v.isoformat()
                elif isinstance(v, Decimal):
                    row[k] = float(v)
        return rows
    except Exception as e:
        return Response(
            content=json.dumps({"error": "서버 오류"}),
            status_code=500,
            media_type="application/json",
        )


# ── 결제 처리 (Y/N 모의 결제) ─────────────────────────────────────────────────
@app.post("/api/payments")
async def process_payment(request: Request):
    body = await request.json()
    reservation_id = body.get("reservationId")
    approved = body.get("approved")
    user_id = request.headers.get("x-amzn-oidc-identity") or body.get("userId")

    if not reservation_id:
        return Response(
            content=json.dumps({"error": "예매 ID 필요"}),
            status_code=400,
            media_type="application/json",
        )

    try:
        async with writer_pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT * FROM reservations WHERE id = %s LIMIT 1",
                    (reservation_id,),
                )
                reservation = await cur.fetchone()

                if not reservation:
                    return Response(
                        content=json.dumps({"error": "예매를 찾을 수 없습니다"}),
                        status_code=404,
                        media_type="application/json",
                    )

                if approved:
                    await cur.execute(
                        "INSERT INTO payments (id, reservation_id, amount, method, status, paid_at) "
                        "VALUES (UUID(), %s, %s, 'CARD', 'PAID', NOW())",
                        (reservation_id, reservation["total_price"]),
                    )
                    await cur.execute(
                        "UPDATE reservations SET status = 'CONFIRMED' WHERE id = %s",
                        (reservation_id,),
                    )
                    log.info("결제 승인: reservationId=%s", reservation_id)
                    return {
                        "status": "CONFIRMED",
                        "reservationId": reservation_id,
                        "amount": float(reservation["total_price"]),
                    }
                else:
                    await cur.execute(
                        "INSERT INTO payments (id, reservation_id, amount, method, status) "
                        "VALUES (UUID(), %s, %s, 'CARD', 'FAILED')",
                        (reservation_id, reservation["total_price"]),
                    )
                    await cur.execute(
                        "UPDATE reservations SET status = 'CANCELLED' WHERE id = %s",
                        (reservation_id,),
                    )
                    await cur.execute(
                        "UPDATE seats s "
                        "JOIN reservation_seats rs ON s.id = rs.seat_id "
                        "SET s.status = 'AVAILABLE' "
                        "WHERE rs.reservation_id = %s",
                        (reservation_id,),
                    )
                    log.info("결제 거절 — 취소: reservationId=%s", reservation_id)
                    return {"status": "CANCELLED", "reservationId": reservation_id}

    except Exception as e:
        log.error("결제 처리 실패: %s", e)
        return Response(
            content=json.dumps({"error": "결제 처리 중 오류"}),
            status_code=500,
            media_type="application/json",
        )


# ── Prometheus 메트릭 엔드포인트 ──────────────────────────────────────────────
@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "3001")))

Instrumentator().instrument(app).expose(app)
