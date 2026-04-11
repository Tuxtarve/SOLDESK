"""
Amazon ElastiCache for Redis — 조회(read) 캐시 전용 연결 (논리 DB = ELASTICACHE_LOGICAL_DB_CACHE).

SQS 비동기 예매 상태(booking:*)는 `cache.elasticache_booking_client` 의 별도 논리 DB를 쓴다.
동일 소형 노드 1대로 비용을 유지하면서 캐시 리빌드 FLUSHDB 가 예매 폴링 키를 지우지 않게 한다.
원본 데이터는 RDS이며, 채울 때는 get_db_read_connection() (DB_READ_REPLICA_ENABLED 시 리더 우선).
캐시 장애·미스 시 read 라우트는 DB로 폴백한다.

IMPORTANT:
- Do not delete this file. Other modules import `redis_client` from here.
- This module implements the cache "switch" policy:
  - CACHE_ENABLED=false: never touch Redis (no connect/timeout/retry) and behave as cache-miss/no-op.
  - CACHE_ENABLED=true : use real Redis client. If Redis is down, callers may hit retry/timeout in the redis library.
    (That behavior is intentional for the "enabled" mode.)
"""

from typing import Any, Dict, Optional

from config import (
    CACHE_ENABLED,
    ELASTICACHE_LOGICAL_DB_CACHE,
    REDIS_CONNECT_TIMEOUT_SEC,
    REDIS_HEALTH_CHECK_INTERVAL_SEC,
    REDIS_HOST,
    REDIS_MAX_CONNECTIONS,
    REDIS_PORT,
    REDIS_SOCKET_TIMEOUT_SEC,
)


class _NoopRedisClient:
  def get(self, key: str) -> Optional[str]:
    return None

  def mget(self, keys: Any, *args: Any, **kwargs: Any) -> list:
    try:
      n = len(keys)
    except TypeError:
      n = 0
    return [None] * n

  def set(self, key: str, value: Any, *args: Any, **kwargs: Any) -> bool:
    return True

  def setex(self, key: str, ttl_seconds: int, value: Any) -> bool:
    return True

  def delete(self, *keys: Any) -> int:
    return 0

  def flushdb(self) -> bool:
    return True


if not CACHE_ENABLED:
  # hard bypass: do NOT create a Redis client at all.
  redis_client = _NoopRedisClient()
else:
  import redis  # lazy import so CACHE_ENABLED=false doesn't load/initialize redis at all

  _pool_kw: Dict[str, Any] = {
      "host": REDIS_HOST,
      "port": REDIS_PORT,
      "db": int(ELASTICACHE_LOGICAL_DB_CACHE),
      "decode_responses": True,
      "max_connections": REDIS_MAX_CONNECTIONS,
  }
  if REDIS_CONNECT_TIMEOUT_SEC > 0:
      _pool_kw["socket_connect_timeout"] = REDIS_CONNECT_TIMEOUT_SEC
  if REDIS_SOCKET_TIMEOUT_SEC > 0:
      _pool_kw["socket_timeout"] = REDIS_SOCKET_TIMEOUT_SEC
  if REDIS_HEALTH_CHECK_INTERVAL_SEC > 0:
      _pool_kw["health_check_interval"] = REDIS_HEALTH_CHECK_INTERVAL_SEC

  _pool = redis.ConnectionPool(**_pool_kw)
  redis_client = redis.Redis(connection_pool=_pool)
