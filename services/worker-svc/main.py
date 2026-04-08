import os
import json
import asyncio
import logging

from fastapi import FastAPI, Request, Response
from contextlib import asynccontextmanager
import aiomysql
import redis.asyncio as aioredis
import boto3
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST, REGISTRY

# ── 로깅 ──────────────────────────────────────────────────────────────────────
logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker-svc")

# ── Prometheus 메트릭 ─────────────────────────────────────────────────────────
processed_total = Counter(
    "worker_processed_total", "SQS 메시지 처리 수", ["result"],
)
process_duration = Histogram(
    "worker_process_duration_ms", "메시지 처리 시간 (ms)",
    buckets=[50, 100, 300, 500, 1000, 3000],
)

# ── AWS 클라이언트 ────────────────────────────────────────────────────────────
REGION = os.getenv("AWS_REGION", "ap-northeast-2")
SQS_URL = os.getenv("SQS_QUEUE_URL")
sqs_client = boto3.client("sqs", region_name=REGION)

# ── 전역 풀 ───────────────────────────────────────────────────────────────────
writer_pool: aiomysql.Pool | None = None
redis_client: aioredis.Redis | None = None
running = True


async def process_message(msg: dict):
    import time
    start = time.time()
    conn = None

    try:
        body = json.loads(msg["Body"])
        reservation_id = body["reservationId"]
        user_id = body["userId"]
        event_id = body["eventId"]
        seat_ids = body["seatIds"]
        expires_at = body["expiresAt"]
        lock_key = body["lockKey"]

        log.info("메시지 처리 시작: reservationId=%s", reservation_id)

        conn = await writer_pool.acquire()
        await conn.begin()
        cur = await conn.cursor()

        placeholders = ",".join(["%s"] * len(seat_ids))
        await cur.execute(
            f"SELECT id, price FROM seats WHERE id IN ({placeholders}) AND status = 'AVAILABLE' FOR UPDATE",
            seat_ids,
        )
        seat_rows = await cur.fetchall()

        if len(seat_rows) != len(seat_ids):
            await conn.rollback()
            log.warning("좌석 이미 선점됨: reservationId=%s", reservation_id)
            processed_total.labels(result="seat_conflict").inc()
            delete_message(msg["ReceiptHandle"])
            return

        total_price = sum(row[1] for row in seat_rows)

        await cur.execute(
            "INSERT INTO reservations (id, user_id, event_id, status, total_price, expires_at) "
            "VALUES (%s, %s, %s, 'PENDING', %s, %s)",
            (reservation_id, user_id, event_id, total_price, expires_at),
        )

        for seat_id in seat_ids:
            await cur.execute(
                "INSERT INTO reservation_seats (reservation_id, seat_id) VALUES (%s, %s)",
                (reservation_id, seat_id),
            )

        await cur.execute(
            f"UPDATE seats SET status = 'RESERVED' WHERE id IN ({placeholders})",
            seat_ids,
        )

        await conn.commit()
        await cur.close()
        writer_pool.release(conn)
        conn = None

        await redis_client.delete(lock_key)

        processed_total.labels(result="success").inc()
        log.info("예매 확정 완료: reservationId=%s", reservation_id)

    except Exception as e:
        if conn:
            await conn.rollback()
            writer_pool.release(conn)
        processed_total.labels(result="error").inc()
        log.error("메시지 처리 실패: %s", e)
    finally:
        delete_message(msg.get("ReceiptHandle"))
        elapsed = (time.time() - start) * 1000
        process_duration.observe(elapsed)


def delete_message(receipt_handle: str):
    try:
        sqs_client.delete_message(QueueUrl=SQS_URL, ReceiptHandle=receipt_handle)
    except Exception as e:
        log.error("SQS 삭제 실패: %s", e)


async def poll_sqs():
    global running
    while running:
        try:
            resp = sqs_client.receive_message(
                QueueUrl=SQS_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,
            )
            messages = resp.get("Messages", [])
            if not messages:
                continue

            tasks = [process_message(msg) for msg in messages]
            await asyncio.gather(*tasks, return_exceptions=True)

        except Exception as e:
            log.error("SQS 폴링 오류: %s", e)
            await asyncio.sleep(3)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global writer_pool, redis_client, running

    writer_pool = await aiomysql.create_pool(
        host=os.getenv("DB_WRITER_HOST", "127.0.0.1"),
        user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""),
        db=os.getenv("DB_NAME", "ticketing"),
        port=int(os.getenv("DB_PORT", "3306")),
        maxsize=5,
        autocommit=False,
    )
    redis_client = aioredis.Redis(
        host=os.getenv("REDIS_HOST", "127.0.0.1"),
        port=int(os.getenv("REDIS_PORT", "6379")),
        decode_responses=True,
    )
    log.info("worker-svc 시작")

    # SQS 폴링을 백그라운드 태스크로 실행
    poll_task = asyncio.create_task(poll_sqs())
    yield

    running = False
    poll_task.cancel()
    if redis_client:
        await redis_client.close()
    if writer_pool:
        writer_pool.close()
        await writer_pool.wait_closed()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "worker-svc"}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "3002")))
