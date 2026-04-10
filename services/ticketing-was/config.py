"""
환경변수 기반 설정 (EKS ConfigMap/Secret에서 주입)
원본: config.py (하드코딩) → AWS 환경용으로 변환
"""
import os


def _get_bool_env(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        s = str(value).strip().lower()
        if s in ("1", "true", "t", "yes", "y", "on"):
            return True
        if s in ("0", "false", "f", "no", "n", "off"):
            return False
        return default
    except Exception:
        return default

# ── DB (Aurora RDS) ──────────────────────────────────────────────────────────
DB_HOST     = os.getenv("DB_WRITER_HOST", "127.0.0.1")
DB_PORT     = int(os.getenv("DB_PORT", "3306"))
DB_NAME     = os.getenv("DB_NAME", "ticketing")
DB_USER     = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

# Reader 엔드포인트 (읽기 전용 쿼리용 — 현재 코드는 단일 커넥션이라 미사용)
DB_READER_HOST = os.getenv("DB_READER_HOST", DB_HOST)

# ── Redis (ElastiCache) ─────────────────────────────────────────────────────
REDIS_HOST = os.getenv("REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
# 스위치: false면 Redis를 "절대" 사용하지 않고 즉시 DB로 폴백(연결/재시도 0)
CACHE_ENABLED = _get_bool_env("CACHE_ENABLED", True)

# ── SQS ──────────────────────────────────────────────────────────────────────
AWS_REGION    = os.getenv("AWS_REGION", "")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
# 스위치: false면 SQS 호출 자체를 차단한다.
# NOTE: 현재 write-api는 SQS 동기 폴백(DB 직접 커밋)이 제거된 상태라,
# SQS_ENABLED=false에서 예매 커밋을 "DB로 즉시" 돌리려면 동기 커밋 경로를 복원해야 한다.
SQS_ENABLED = _get_bool_env("SQS_ENABLED", True)

# ── API 포트 ─────────────────────────────────────────────────────────────────
READ_API_HOST  = "0.0.0.0"
READ_API_PORT  = int(os.getenv("READ_API_PORT", "5000"))
WRITE_API_HOST = "0.0.0.0"
WRITE_API_PORT = int(os.getenv("WRITE_API_PORT", "5001"))
