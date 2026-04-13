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


def _get_int_env(name: str, default: int, minimum: int = 0) -> int:
    raw = os.getenv(name)
    if raw is None or str(raw).strip() == "":
        return max(minimum, default)
    try:
        return max(minimum, int(str(raw).strip(), 10))
    except ValueError:
        return max(minimum, default)


# ── DB (Aurora RDS) ──────────────────────────────────────────────────────────
# Writer = 본 DB. Reader = 조회 레플리카(없으면 WRITER 와 동일 값 두면 됨 → 단일 RDS 실험).
DB_HOST     = os.getenv("DB_WRITER_HOST", "127.0.0.1")
DB_PORT     = int(os.getenv("DB_PORT", "3306"))
DB_NAME     = os.getenv("DB_NAME", "ticketing")
DB_USER     = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

DB_READER_HOST = os.getenv("DB_READER_HOST", DB_HOST)
# R/O 리플리카를 쓸 시점 전이면 false 유지(기본). true + DB_READER_HOST 분리 시에만 리더 우선·실패 시 writer.
DB_READ_REPLICA_ENABLED = _get_bool_env("DB_READ_REPLICA_ENABLED", False)

# ── Amazon ElastiCache for Redis (단일 소형 클러스터, RDS/SQS와 동일 VPC 내) ──
# 엔드포인트: Terraform output → Secret 에 ELASTICACHE_PRIMARY_ENDPOINT 권장(REDIS_HOST 폴백 호환).
ELASTICACHE_PRIMARY_ENDPOINT = os.getenv("ELASTICACHE_PRIMARY_ENDPOINT", "").strip()
REDIS_HOST = ELASTICACHE_PRIMARY_ENDPOINT or os.getenv("REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(os.getenv("REDIS_PORT", os.getenv("ELASTICACHE_PORT", "6379")))
# 0 = 미설정(라이브러리 기본). ElastiCache·K8s에서 장시간 유휴 연결 끊김 대비 health_check 권장.
REDIS_MAX_CONNECTIONS = _get_int_env("REDIS_MAX_CONNECTIONS", 50, minimum=1)
REDIS_SOCKET_TIMEOUT_SEC = _get_int_env("REDIS_SOCKET_TIMEOUT_SEC", 5, minimum=0)
REDIS_CONNECT_TIMEOUT_SEC = _get_int_env("REDIS_CONNECT_TIMEOUT_SEC", 3, minimum=0)
REDIS_HEALTH_CHECK_INTERVAL_SEC = _get_int_env("REDIS_HEALTH_CHECK_INTERVAL_SEC", 30, minimum=0)
# 스위치: false면 Redis를 "절대" 사용하지 않고 즉시 DB로 폴백(연결/재시도 0)
CACHE_ENABLED = _get_bool_env("CACHE_ENABLED", True)
# read-api: 시작 시 Redis 웜업(로컬 systemd 타이머와 유사). CACHE_ENABLED=false면 무시.
CACHE_WARMUP_ENABLED = _get_bool_env("CACHE_WARMUP_ENABLED", True)

CACHE_WARMUP_TOTAL_RUNS = _get_int_env("CACHE_WARMUP_TOTAL_RUNS", 5, minimum=1)
CACHE_WARMUP_INTERVAL_SEC = _get_int_env("CACHE_WARMUP_INTERVAL_SEC", 60, minimum=0)
# true: 주기 웜업 시 영화/극장 전체 리빌드 생략, 콘서트 목록만 갱신(대규모 오픈 시 부하 완화).
CACHE_WARMUP_REPEAT_LIGHT = _get_bool_env("CACHE_WARMUP_REPEAT_LIGHT", False)

# 논리 DB 분리: 노드 1대·요금 동일 → 조회 캐시 FLUSHDB 가 SQS 예매 키(booking:*)를 건드리지 않음.
# (클러스터 모드 Redis에서는 미지원 — 현재 Terraform은 단일 노드 replication group)
def _elasticache_db_index(name: str, default: int) -> int:
    return min(15, _get_int_env(name, default, minimum=0))


ELASTICACHE_LOGICAL_DB_CACHE = _elasticache_db_index("ELASTICACHE_LOGICAL_DB_CACHE", 0)
ELASTICACHE_LOGICAL_DB_BOOKING = _elasticache_db_index("ELASTICACHE_LOGICAL_DB_BOOKING", 1)
if ELASTICACHE_LOGICAL_DB_BOOKING == ELASTICACHE_LOGICAL_DB_CACHE:
    ELASTICACHE_LOGICAL_DB_BOOKING = (ELASTICACHE_LOGICAL_DB_CACHE + 1) % 16

# 콘서트 회차 스냅샷 concert:show:{id}:read:v2 — 만료 시 자연 미스로 DB 재조회(무효화 누락 보완·동시 만료 완화).
# 0 이면 TTL 없음(기존과 동일). 지터는 base의 ±JITTER% 범위(최소 1초).
CONCERT_SHOW_SNAPSHOT_TTL_SEC = _get_int_env("CONCERT_SHOW_SNAPSHOT_TTL_SEC", 90, minimum=0)
CONCERT_SHOW_SNAPSHOT_TTL_JITTER_PCT = _get_int_env("CONCERT_SHOW_SNAPSHOT_TTL_JITTER_PCT", 20, minimum=0)

# 콘서트 Redis 웜업: minimal = 공연 목록만(필수 메타); full = 목록 + 공연별 상세 키 전부(공연 수 많으면 부담).
CONCERT_CACHE_WARMUP_MODE = os.getenv("CONCERT_CACHE_WARMUP_MODE", "minimal").strip().lower()
# 부트스트랩 시 회차 행 목록 캐시 TTL(초). 0이면 Redis에 메타 목록을 두지 않고 매번 DB(대규모 오픈 시 DB 부담).
CONCERT_SHOWS_META_TTL_SEC = _get_int_env("CONCERT_SHOWS_META_TTL_SEC", 120, minimum=0)
# 공연 목록·상세 Redis TTL(초). 0 = 만료 없음. 목록만 짧게 두고 상세는 길게 두는 식으로 운영 가능.
CONCERTS_LIST_CACHE_TTL_SEC = _get_int_env("CONCERTS_LIST_CACHE_TTL_SEC", 0, minimum=0)
CONCERT_DETAIL_CACHE_TTL_SEC = _get_int_env("CONCERT_DETAIL_CACHE_TTL_SEC", 0, minimum=0)

# 콘서트 좌석 홀드(접수 확정) TTL(초): Write API에서 좌석을 먼저 홀드하고, Read/UI는 홀드 수를 즉시 remain에 반영.
# worker가 DB에 최종 커밋을 하더라도 UI는 "확정된(홀드된) 수량" 기준으로 즉시 줄어든 값을 보게 된다.
CONCERT_SEAT_HOLD_TTL_SEC = _get_int_env("CONCERT_SEAT_HOLD_TTL_SEC", 600, minimum=10)

# ── 향후 Cognito + API Gateway (지금은 미사용 · AUTH_MODE=legacy 유지) ────────
# JWT 검증은 나중에 JWKS/issuer 기준으로 붙이면 됨. DB에 토큰 저장은 필수 아님.
AUTH_MODE = os.getenv("AUTH_MODE", "legacy").strip().lower()
COGNITO_ISSUER = os.getenv("COGNITO_ISSUER", "").strip()
COGNITO_JWKS_URI = os.getenv("COGNITO_JWKS_URI", "").strip()
COGNITO_APP_CLIENT_ID = os.getenv("COGNITO_APP_CLIENT_ID", "").strip()

# ── SQS ──────────────────────────────────────────────────────────────────────
AWS_REGION    = os.getenv("AWS_REGION", "")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
# 스위치: false면 SQS 호출 자체를 차단한다.
# NOTE: 현재 write-api는 SQS 동기 폴백(DB 직접 커밋)이 제거된 상태라,
# SQS_ENABLED=false에서 예매 커밋을 "DB로 즉시" 돌리려면 동기 커밋 경로를 복원해야 한다.
SQS_ENABLED = _get_bool_env("SQS_ENABLED", True)
# boto3 SQS 클라이언트: 스로틀·일시 오류 재시도 (standard | adaptive)
SQS_BOTO_MAX_ATTEMPTS = _get_int_env("SQS_BOTO_MAX_ATTEMPTS", 5, minimum=1)
SQS_BOTO_RETRY_MODE = os.getenv("SQS_BOTO_RETRY_MODE", "adaptive").strip().lower()
SQS_CONNECT_TIMEOUT_SEC = _get_int_env("SQS_CONNECT_TIMEOUT_SEC", 5, minimum=1)
SQS_READ_TIMEOUT_SEC = _get_int_env("SQS_READ_TIMEOUT_SEC", 30, minimum=1)

# 예매 비동기: SQS 수락 후 ElastiCache `booking:queued:{ref}` TTL(초). 폴링 시 PROCESSING vs 무효 ref 구분에 사용.
BOOKING_QUEUED_TTL_SEC = _get_int_env("BOOKING_QUEUED_TTL_SEC", 7200, minimum=60)

# SQS 예매를 켠 경우 예매 상태(booking:*) ElastiCache는 필수 — worker·write-api 불일치 방지로 자동 True.
BOOKING_STATE_ENABLED = _get_bool_env("BOOKING_STATE_ENABLED", True)
if SQS_ENABLED and str(SQS_QUEUE_URL or "").strip():
    BOOKING_STATE_ENABLED = True

# ── API 포트 ─────────────────────────────────────────────────────────────────
READ_API_HOST  = "0.0.0.0"
READ_API_PORT  = int(os.getenv("READ_API_PORT", "5000"))
WRITE_API_HOST = "0.0.0.0"
WRITE_API_PORT = int(os.getenv("WRITE_API_PORT", "5001"))
