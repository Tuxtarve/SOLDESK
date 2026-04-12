import os
import json
import signal
import asyncio
import logging
from decimal import Decimal

from fastapi import FastAPI, Request, Response
from contextlib import asynccontextmanager
import aiomysql
import redis.asyncio as aioredis
from prometheus_client import Counter, Histogram, CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST, REGISTRY
from prometheus_client import multiprocess

# ── 로깅 ──────────────────────────────────────────────────────────────────────
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("event-svc")

# ── Prometheus 메트릭 ─────────────────────────────────────────────────────────
http_requests = Counter(
    "event_svc_http_requests_total", "HTTP 요청 총 수",
    ["method", "path", "status"],
)
http_duration = Histogram(
    "event_svc_http_duration_ms", "HTTP 요청 처리 시간 (ms)",
    ["method", "path"],
    buckets=[10, 50, 100, 300, 500, 1000, 3000],
)
cache_hits = Counter(
    "event_svc_cache_hits_total", "Redis 캐시 히트 수",
    ["key_type"],
)

# ── 전역 풀 ───────────────────────────────────────────────────────────────────
reader_pool: aiomysql.Pool | None = None
redis_client: aioredis.Redis | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global reader_pool, redis_client

    reader_pool = await aiomysql.create_pool(
        host=os.getenv("DB_READER_HOST", "127.0.0.1"),
        user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""),
        db=os.getenv("DB_NAME", "ticketing"),
        port=int(os.getenv("DB_PORT", "3306")),
        maxsize=3,
        autocommit=True,
    )
    redis_client = aioredis.Redis(
        host=os.getenv("REDIS_HOST", "127.0.0.1"),
        port=int(os.getenv("REDIS_PORT", "6379")),
        decode_responses=True,
    )
    log.info("event-svc 시작, port=%s", os.getenv("PORT", "3000"))
    yield

    # 종료
    if redis_client:
        await redis_client.close()
    if reader_pool:
        reader_pool.close()
        await reader_pool.wait_closed()
    log.info("event-svc 종료")


app = FastAPI(lifespan=lifespan)


# ── 미들웨어 (메트릭 수집) ────────────────────────────────────────────────────
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    import time
    start = time.time()
    response = await call_next(request)
    elapsed_ms = (time.time() - start) * 1000
    http_duration.labels(method=request.method, path=request.url.path).observe(elapsed_ms)
    http_requests.labels(method=request.method, path=request.url.path, status=response.status_code).inc()
    return response


# ── 헬스체크 ──────────────────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz():
    return {"status": "ok", "service": "event-svc"}


@app.get("/health")
async def health():
    try:
        async with reader_pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SELECT 1")
        return {"status": "ok", "service": "event-svc", "db": "connected"}
    except Exception as e:
        return Response(
            content=json.dumps({"status": "error", "message": str(e)}),
            status_code=503,
            media_type="application/json",
        )


# ── 이벤트 목록 조회 ──────────────────────────────────────────────────────────
@app.get("/api/events")
async def list_events():
    try:
        cache_key = "events:list"
        cached = await redis_client.get(cache_key)
        if cached:
            cache_hits.labels(key_type="events_list").inc()
            return json.loads(cached)

        async with reader_pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("""
                    SELECT e.id, e.title, e.venue, e.start_at, e.total_seats,
                           COUNT(CASE WHEN s.status = 'AVAILABLE' THEN 1 END) AS available_seats,
                           MIN(s.price) AS min_price,
                           e.status, e.thumbnail_url
                    FROM events e
                    LEFT JOIN seats s ON s.event_id = e.id
                    WHERE e.status IN ('ON_SALE', 'SOLD_OUT')
                    GROUP BY e.id
                    ORDER BY e.start_at ASC
                    LIMIT 50
                """)
                rows = await cur.fetchall()

        # datetime / Decimal 직렬화 처리
        for row in rows:
            for k, v in row.items():
                if hasattr(v, "isoformat"):
                    row[k] = v.isoformat()
                elif isinstance(v, Decimal):
                    row[k] = float(v)

        await redis_client.setex(cache_key, 30, json.dumps(rows, default=str))
        return rows
    except Exception as e:
        log.error("이벤트 목록 조회 실패: %s", e)
        return Response(
            content=json.dumps({"error": "서버 오류"}),
            status_code=500,
            media_type="application/json",
        )


# ── 좌석 현황 조회 ────────────────────────────────────────────────────────────
@app.get("/api/events/{event_id}/seats")
async def get_seats(event_id: str):
    try:
        cache_key = f"seats:{event_id}"
        cached = await redis_client.get(cache_key)
        if cached:
            cache_hits.labels(key_type="seats").inc()
            return json.loads(cached)

        async with reader_pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT id, section, `row`, number, grade, price, status "
                    "FROM seats WHERE event_id = %s ORDER BY section, `row`, number",
                    (event_id,),
                )
                rows = await cur.fetchall()

        available = await redis_client.get(f"seat:available:{event_id}")
        result = {
            "eventId": event_id,
            "seats": rows,
            "availableCount": int(available) if available else sum(1 for s in rows if s["status"] == "AVAILABLE"),
        }

        await redis_client.setex(cache_key, 5, json.dumps(result, default=str))
        return result
    except Exception as e:
        log.error("좌석 조회 실패: id=%s, err=%s", event_id, e)
        return Response(
            content=json.dumps({"error": "서버 오류"}),
            status_code=500,
            media_type="application/json",
        )


# ── Prometheus 메트릭 엔드포인트 ──────────────────────────────────────────────
@app.get("/metrics")
@app.get("/event-metrics")
async def metrics():
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "3000")))
