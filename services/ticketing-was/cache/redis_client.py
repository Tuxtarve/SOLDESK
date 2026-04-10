"""
Redis client wiring.

IMPORTANT:
- Do not delete this file. Other modules import `redis_client` from here.
- This module implements the cache "switch" policy:
  - CACHE_ENABLED=false: never touch Redis (no connect/timeout/retry) and behave as cache-miss/no-op.
  - CACHE_ENABLED=true : use real Redis client. If Redis is down, callers may hit retry/timeout in the redis library.
    (That behavior is intentional for the "enabled" mode.)
"""

from typing import Any, Optional

from config import CACHE_ENABLED, REDIS_HOST, REDIS_PORT


class _NoopRedisClient:
  def get(self, key: str) -> Optional[str]:
    return None

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

  redis_client = redis.Redis(
      host=REDIS_HOST,
      port=REDIS_PORT,
      decode_responses=True,
  )
