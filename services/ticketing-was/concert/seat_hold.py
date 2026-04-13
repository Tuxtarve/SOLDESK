from __future__ import annotations

import json
import time
from typing import Dict, List, Tuple

from cache.redis_client import redis_client
from config import CONCERT_SEAT_HOLD_TTL_SEC


def _seat_key(show_id: int, row: int, col: int) -> str:
    return f"concert:seat:{int(show_id)}:{int(row)}-{int(col)}:hold:v1"


def _reserved_set_key(show_id: int) -> str:
    return f"concert:reserved:{int(show_id)}:v1"


def _hold_meta_key(booking_ref: str) -> str:
    return f"concert:holdmeta:{booking_ref}:v1"


def try_hold_seats(
    *,
    show_id: int,
    seats: List[Tuple[int, int]],
    booking_ref: str,
    ttl_sec: int | None = None,
) -> Dict:
    """
    좌석을 Redis에서 선점(접수 확정)한다.
    - seat key: SET NX EX ttl (booking_ref)
    - reserved set: SADD "r-c" (UI/조회 remain 계산 + reserved_seats 제공)
    - hold meta: booking_ref → {show_id, seats[]} (실패 롤백용)
    """
    ttl = int(ttl_sec or CONCERT_SEAT_HOLD_TTL_SEC)
    ttl = max(10, ttl)
    if not seats:
        return {"ok": False, "code": "NO_SEATS"}

    held: List[Tuple[int, int]] = []
    pipe = redis_client.pipeline()
    for r, c in seats:
        pipe.set(_seat_key(show_id, r, c), booking_ref, nx=True, ex=ttl)
    results = pipe.execute()

    for (r, c), ok in zip(seats, results):
        if ok:
            held.append((r, c))
        else:
            # 하나라도 실패하면 전부 롤백(요청 단위 원자성)
            release_seats(show_id=show_id, seats=held, booking_ref=booking_ref)
            return {"ok": False, "code": "DUPLICATE_SEAT"}

    # 예약 좌석 set 갱신 (remain 즉시 반영)
    pipe2 = redis_client.pipeline()
    set_key = _reserved_set_key(show_id)
    for r, c in held:
        pipe2.sadd(set_key, f"{int(r)}-{int(c)}")
    pipe2.expire(set_key, ttl)
    meta = {
        "show_id": int(show_id),
        "seats": [f"{int(r)}-{int(c)}" for r, c in held],
        "ttl_sec": ttl,
        "created_at_epoch_ms": int(time.time() * 1000),
    }
    pipe2.setex(_hold_meta_key(booking_ref), ttl, json.dumps(meta, ensure_ascii=False))
    pipe2.execute()
    return {"ok": True, "code": "HELD", "ttl_sec": ttl}


def release_seats(*, show_id: int, seats: List[Tuple[int, int]], booking_ref: str) -> None:
    if not seats:
        return
    pipe = redis_client.pipeline()
    for r, c in seats:
        pipe.get(_seat_key(show_id, r, c))
    existing = pipe.execute()

    pipe2 = redis_client.pipeline()
    set_key = _reserved_set_key(show_id)
    for (r, c), v in zip(seats, existing):
        # 내가 잡은 홀드만 해제(다른 booking_ref의 홀드는 건드리지 않음)
        if str(v or "") == str(booking_ref):
            pipe2.delete(_seat_key(show_id, r, c))
            pipe2.srem(set_key, f"{int(r)}-{int(c)}")
    pipe2.execute()


def reserved_seats_snapshot(show_id: int) -> List[str]:
    try:
        return list(redis_client.smembers(_reserved_set_key(show_id)) or [])
    except Exception:
        return []


def reserved_count(show_id: int) -> int:
    try:
        return int(redis_client.scard(_reserved_set_key(show_id)) or 0)
    except Exception:
        return 0

