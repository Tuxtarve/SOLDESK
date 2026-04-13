"""
콘서트 조회용 Redis 캐시.

부트스트랩 응답은 API 형태로는 { concert, shows[] } 이지만, 변동이 큰 데이터는
회차(show_id)별 스냅샷 키(`concert:show:{id}:read:v2`)에만 둔다. 예매 1건당 이 키만 무효화·재적재.

기동 웜업(CONCERT_CACHE_WARMUP_MODE=minimal): 공연 목록만 Redis; 공연 상세·회차 스냅샷은 요청 시 적재.
회차 행 목록은 `concert:shows_meta:{concert_id}:read:v1` 로 짧게 캐시해 부트스트랩 DB QPS를 줄인다.
스냅샷 재적재 시 DB에서 해당 show 1행을 항상 다시 읽어 잔여·상태를 맞춘다(배치 reserved + shows_meta 조합에도 동일).
부트스트랩 MGET은 키가 많을 때를 대비해 청크(128)로 나눈다. show 락은 고정 샤드(1024)로 메모리 누수를 막는다.

올리지 않는 것: user_id, 이메일, 예매자 식별, 결제 식별자 등 회원/예매 PII.
"""
from __future__ import annotations

import json
import random
import threading
from typing import Any, Dict, List, Optional

from cache.redis_client import redis_client
from concert.sale_state import mget_sale_states
from concert.seat_hold import reserved_count, reserved_seats_snapshot
from config import (
    CONCERT_CACHE_WARMUP_MODE,
    CONCERT_DETAIL_CACHE_TTL_SEC,
    CONCERT_SHOW_SNAPSHOT_TTL_JITTER_PCT,
    CONCERT_SHOW_SNAPSHOT_TTL_SEC,
    CONCERT_SHOWS_META_TTL_SEC,
    CONCERTS_LIST_CACHE_TTL_SEC,
)
from db import get_db_read_connection

CONCERTS_LIST_KEY = "concerts:list:read:v1"


def _concert_shows_meta_key(concert_id: int) -> str:
    """공연 단위 회차 행 목록(스냅샷과 별도). 예매로 잔여만 바뀌면 이 키는 무효화하지 않는다."""
    return f"concert:shows_meta:{int(concert_id)}:read:v1"

# 회차별 스냅샷 적재 동시성: 동일 show_id 직렬화. 고정 샤드로 Lock 딕셔너리 무한 증가 방지.
_SHOW_FILL_LOCK_SHARDS = 1024
_show_fill_lock_shards: tuple[threading.Lock, ...] = tuple(
    threading.Lock() for _ in range(_SHOW_FILL_LOCK_SHARDS)
)


def _lock_for_show_fill(show_id: int) -> threading.Lock:
    return _show_fill_lock_shards[abs(int(show_id)) % _SHOW_FILL_LOCK_SHARDS]


def _redis_mget_values(keys: List[str], chunk_size: int = 128) -> List[Optional[str]]:
    if not keys:
        return []
    out: List[Optional[str]] = []
    for i in range(0, len(keys), chunk_size):
        chunk = keys[i : i + chunk_size]
        out.extend(redis_client.mget(chunk))
    return out


def _snapshot_ttl_seconds() -> Optional[int]:
    base = int(CONCERT_SHOW_SNAPSHOT_TTL_SEC)
    if base <= 0:
        return None
    j = max(0, min(50, int(CONCERT_SHOW_SNAPSHOT_TTL_JITTER_PCT)))
    lo = int(base * (100 - j) / 100)
    hi = int(base * (100 + j) / 100)
    lo = max(1, lo)
    hi = max(lo, hi)
    return random.randint(lo, hi)


def _concert_detail_key(concert_id: int) -> str:
    return f"concert:detail:{int(concert_id)}:read:v1"


def _concert_bootstrap_key(concert_id: int) -> str:
    """레거시 공연 단위 부트스트랩 키 — 무효화 시 삭제만 한다."""
    return f"concert:bootstrap:{int(concert_id)}:read:v1"


def _concert_show_snapshot_key(show_id: int) -> str:
    return f"concert:show:{int(show_id)}:read:v2"


def _serialize_dt(value: Any) -> Optional[str]:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat(sep=" ", timespec="seconds")
    return str(value)


def _fetch_concerts_from_db() -> List[Dict[str, Any]]:
    conn = get_db_read_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT c.concert_id, c.title, c.category, c.genre, c.venue_summary,
                    c.poster_url, c.runtime_minutes, c.synopsis, c.synopsis_line,
                    c.status, c.hide, s.next_show_date
                FROM concerts c
                LEFT JOIN (
                    SELECT concert_id, MIN(show_date) AS next_show_date
                    FROM concert_shows GROUP BY concert_id
                ) s ON s.concert_id = c.concert_id
                ORDER BY concert_id ASC
            """)
            rows = cur.fetchall() or []
        out: List[Dict[str, Any]] = []
        for r in rows:
            out.append({
                "concert_id": int(r["concert_id"]), "title": r.get("title"),
                "category": r.get("category"), "genre": r.get("genre"),
                "venue_summary": r.get("venue_summary"), "poster_url": r.get("poster_url"),
                "runtime_minutes": int(r.get("runtime_minutes") or 0),
                "synopsis": r.get("synopsis"), "synopsis_line": r.get("synopsis_line"),
                "status": r.get("status"), "hide": r.get("hide"),
                "next_show_date": _serialize_dt(r.get("next_show_date")),
            })
        return out
    finally:
        conn.close()


def _fetch_concert_row(concert_id: int) -> Optional[Dict[str, Any]]:
    conn = get_db_read_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT concert_id, title, category, genre, venue_summary, poster_url,
                    runtime_minutes, synopsis, synopsis_line, status, hide
                FROM concerts WHERE concert_id = %s
            """, (concert_id,))
            r = cur.fetchone()
        if not r:
            return None
        return {
            "concert_id": int(r["concert_id"]), "title": r.get("title"),
            "category": r.get("category"), "genre": r.get("genre"),
            "venue_summary": r.get("venue_summary"), "poster_url": r.get("poster_url"),
            "runtime_minutes": int(r.get("runtime_minutes") or 0),
            "synopsis": r.get("synopsis"), "synopsis_line": r.get("synopsis_line"),
            "status": r.get("status"), "hide": r.get("hide"),
            "release_date": None, "release_date_display": None,
        }
    finally:
        conn.close()


def _fetch_concert_show_rows(concert_id: int) -> List[Dict[str, Any]]:
    conn = get_db_read_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT show_id, concert_id, show_date, venue_name, venue_address,
                    hall_name, seat_rows, seat_cols, total_count, remain_count, price, status
                FROM concert_shows WHERE concert_id = %s ORDER BY show_date ASC
            """, (concert_id,))
            return list(cur.fetchall() or [])
    finally:
        conn.close()


def _get_show_rows_for_bootstrap(concert_id: int) -> List[Dict[str, Any]]:
    """
    부트스트랩용 회차 행 목록. Redis 메타 TTL>0이면 캐시(스냅샷과 독립; 예매로 스냅샷만 갱신).
    """
    ttl = int(CONCERT_SHOWS_META_TTL_SEC)
    if ttl <= 0:
        return _fetch_concert_show_rows(concert_id)
    key = _concert_shows_meta_key(concert_id)
    raw = redis_client.get(key)
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                return data
        except json.JSONDecodeError:
            redis_client.delete(key)
    rows = _fetch_concert_show_rows(concert_id)
    if rows:
        val = json.dumps(rows, default=str, ensure_ascii=False)
        redis_client.set(key, val, ex=ttl)
    return rows


def _fetch_concert_show_row(concert_id: int, show_id: int) -> Optional[Dict[str, Any]]:
    conn = get_db_read_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT show_id, concert_id, show_date, venue_name, venue_address,
                    hall_name, seat_rows, seat_cols, total_count, remain_count, price, status
                FROM concert_shows WHERE concert_id = %s AND show_id = %s
            """, (concert_id, show_id))
            r = cur.fetchone()
        return dict(r) if r else None
    finally:
        conn.close()


def _fetch_reserved_seat_keys_by_show(show_ids: List[int]) -> Dict[str, List[str]]:
    if not show_ids:
        return {}
    # 1) Redis 홀드/확정 좌석이 있으면 그걸 우선 사용(즉시성)
    out: Dict[str, List[str]] = {}
    try:
        for sid in show_ids:
            keys = reserved_seats_snapshot(int(sid))
            if keys:
                out[str(int(sid))] = sorted(keys, key=lambda x: (int(x.split("-")[0]), int(x.split("-")[1])))
        if len(out) == len(show_ids):
            return out
    except Exception:
        # fall through to DB snapshot
        pass

    # 2) fallback: DB에서 ACTIVE 좌석을 읽는다(배포 직후 Redis 미사용/미스 등)
    conn = get_db_read_connection()
    try:
        placeholders = ",".join(["%s"] * len(show_ids))
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT show_id, seat_row_no, seat_col_no FROM concert_booking_seats "
                f"WHERE show_id IN ({placeholders}) AND UPPER(COALESCE(status, '')) = 'ACTIVE' "
                f"ORDER BY show_id, seat_row_no, seat_col_no",
                tuple(show_ids),
            )
            rows = cur.fetchall() or []
        result: Dict[str, List[str]] = dict(out)
        for r in rows:
            sid = str(int(r["show_id"]))
            key = f"{int(r['seat_row_no'])}-{int(r['seat_col_no'])}"
            result.setdefault(sid, []).append(key)
        return result
    finally:
        conn.close()


def _show_payload_from_row(r: Dict[str, Any], reserved_keys: List[str]) -> Dict[str, Any]:
    sid = int(r["show_id"])
    total = int(r.get("total_count") or 0)
    hold = reserved_count(sid)
    # write-path에서 remain_count를 강하게 갱신하지 않는 대신,
    # 조회 스냅샷에서는 예약된 ACTIVE 좌석 수로 remain을 유도한다.
    remain = max(0, total - len(reserved_keys))
    return {
        "show_id": sid,
        "concert_id": int(r["concert_id"]),
        "show_date": _serialize_dt(r.get("show_date")),
        "venue_name": r.get("venue_name"),
        "venue_address": r.get("venue_address"),
        "hall_name": r.get("hall_name"),
        "seat_rows": int(r.get("seat_rows") or 0),
        "seat_cols": int(r.get("seat_cols") or 0),
        "total_count": total,
        # 점유(홀드) 좌석 수 — DB 확정과 별개로 UI에 즉시 반영되는 수량
        "hold_count": int(hold),
        "remain_count": remain,
        "price": int(r.get("price") or 0),
        "status": "CLOSED" if remain <= 0 else (r.get("status") or "OPEN"),
        "reserved_seats": reserved_keys,
    }


def _build_show_snapshot_from_row(row: Dict[str, Any]) -> Dict[str, Any]:
    sid = int(row["show_id"])
    reserved_map = _fetch_reserved_seat_keys_by_show([sid])
    reserved_keys = reserved_map.get(str(sid), [])
    return _show_payload_from_row(row, reserved_keys)


def _store_show_snapshot(payload: Dict[str, Any]) -> None:
    sid = int(payload["show_id"])
    key = _concert_show_snapshot_key(sid)
    val = json.dumps(payload, default=str, ensure_ascii=False)
    ex = _snapshot_ttl_seconds()
    if ex is not None:
        redis_client.set(key, val, ex=ex)
    else:
        redis_client.set(key, val)


def _coalesced_fill_show_snapshot(
    row: Dict[str, Any],
    reserved_keys: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """
    Redis 미스 시에만: show_id 단위 락으로 동시에 한 번만 DB(또는 배치에서 넘긴 reserved)로 채운다.
    reserved_keys 가 있으면 좌석 IN 쿼리 생략(부트스트랩 배치 경로).
    """
    sid = int(row["show_id"])
    key = _concert_show_snapshot_key(sid)
    raw = redis_client.get(key)
    if raw:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            redis_client.delete(key)
    with _lock_for_show_fill(sid):
        raw = redis_client.get(key)
        if raw:
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                redis_client.delete(key)
        # 배치/단건 공통: 스냅샷을 새로 쓸 때는 항상 해당 회차 1행을 DB에서 다시 읽어
        # shows_meta 캐시·배치 reserved 경로 모두에서 잔여/상태 정합성을 맞춘다.
        cid = int(row.get("concert_id") or 0)
        if cid > 0:
            fr = _fetch_concert_show_row(cid, sid)
            if fr:
                row = fr
        if reserved_keys is not None:
            payload = _show_payload_from_row(row, reserved_keys)
        else:
            payload = _build_show_snapshot_from_row(row)
        _store_show_snapshot(payload)
        return payload


def get_or_load_concert_show_snapshot(row: Dict[str, Any]) -> Dict[str, Any]:
    """회차 1건 Redis 스냅샷 (miss 시 DB 좌석만 조회 후 적재, 프로세스 내 싱글플라이트)."""
    return _coalesced_fill_show_snapshot(row, reserved_keys=None)


def build_concert_detail_api_dict(concert_id: int) -> Optional[Dict[str, Any]]:
    concert = _fetch_concert_row(concert_id)
    if not concert:
        return None
    concert = dict(concert)
    concert["release_date_display"] = concert.get("venue_summary") or ""
    return {"concert": concert}


def get_concerts_list_cached_or_load() -> List[Dict[str, Any]]:
    raw = redis_client.get(CONCERTS_LIST_KEY)
    if raw:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            redis_client.delete(CONCERTS_LIST_KEY)
    rows = _fetch_concerts_from_db()
    val = json.dumps(rows, default=str, ensure_ascii=False)
    ttl = int(CONCERTS_LIST_CACHE_TTL_SEC)
    if ttl > 0:
        redis_client.set(CONCERTS_LIST_KEY, val, ex=ttl)
    else:
        redis_client.set(CONCERTS_LIST_KEY, val)
    return rows


def get_concert_detail_cached_or_load(concert_id: int) -> Optional[Dict[str, Any]]:
    key = _concert_detail_key(concert_id)
    raw = redis_client.get(key)
    if raw:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            redis_client.delete(key)
    payload = build_concert_detail_api_dict(concert_id)
    if payload is not None:
        val = json.dumps(payload, default=str, ensure_ascii=False)
        ttl = int(CONCERT_DETAIL_CACHE_TTL_SEC)
        if ttl > 0:
            redis_client.set(key, val, ex=ttl)
        else:
            redis_client.set(key, val)
    return payload


def _concert_header_for_bootstrap(concert_id: int) -> Optional[Dict[str, Any]]:
    detail = get_concert_detail_cached_or_load(concert_id)
    if not detail:
        return None
    concert = dict(detail["concert"])
    if not concert.get("release_date_display"):
        concert["release_date_display"] = concert.get("venue_summary") or ""
    return concert


def get_concert_bootstrap_cached_or_load(concert_id: int) -> Optional[Dict[str, Any]]:
    """목록·회차 메타는 DB 한 번, 회차별 잔여·선점은 show 스냅샷 키로 분리 (MGET 1회)."""
    concert = _concert_header_for_bootstrap(concert_id)
    if not concert:
        return None
    show_rows = _get_show_rows_for_bootstrap(concert_id)
    if not show_rows:
        return {"concert": concert, "shows": []}
    sale_map = mget_sale_states([int(r["show_id"]) for r in show_rows])
    keys = [_concert_show_snapshot_key(int(r["show_id"])) for r in show_rows]
    raws = _redis_mget_values(keys)
    slot: List[Optional[Dict[str, Any]]] = [None] * len(show_rows)
    missed: List[tuple[int, Dict[str, Any]]] = []
    for i, (row, raw, key) in enumerate(zip(show_rows, raws, keys)):
        if raw:
            try:
                snap = json.loads(raw)
                if isinstance(snap, dict):
                    sid = str(int(row["show_id"]))
                    snap["sale"] = sale_map.get(sid, {"status": "OPEN", "close_at_epoch_ms": None})
                slot[i] = snap
                continue
            except json.JSONDecodeError:
                redis_client.delete(key)
        missed.append((i, row))
    if missed:
        miss_ids = [int(r["show_id"]) for _, r in missed]
        reserved_bulk = _fetch_reserved_seat_keys_by_show(miss_ids)
        for i, row in missed:
            sid = int(row["show_id"])
            slot[i] = _coalesced_fill_show_snapshot(
                row,
                reserved_keys=reserved_bulk.get(str(sid), []),
            )
    shows_filled: List[Dict[str, Any]] = [s for s in slot if s is not None]
    return {"concert": concert, "shows": shows_filled}


def get_concert_bootstrap_for_show(concert_id: int, show_id: int) -> Optional[Dict[str, Any]]:
    """선택 회차만 캐시/재조회 (서버 동기화·폴링용)."""
    row = _fetch_concert_show_row(concert_id, show_id)
    if not row:
        return None
    concert = _concert_header_for_bootstrap(concert_id)
    if not concert:
        return None
    snap = get_or_load_concert_show_snapshot(row)
    snap = dict(snap) if isinstance(snap, dict) else {"show_id": int(show_id)}
    snap["sale"] = mget_sale_states([int(show_id)]).get(str(int(show_id)), {"status": "OPEN", "close_at_epoch_ms": None})
    return {"concert": concert, "shows": [snap]}


def warmup_concert_caches() -> Dict[str, Any]:
    """
    서버 기동 시: 공연 목록(필수 메타)만 Redis에 두는 것이 기본(minimal).
    full 모드일 때만 공연별 상세 키를 일괄 적재(공연 수가 많으면 ElastiCache/기동 시간 부담).
    회차 스냅샷은 예매·부트스트랩 요청 시 per-show 적재 + TTL.
    """
    mode = (CONCERT_CACHE_WARMUP_MODE or "minimal").strip().lower()
    if mode not in ("full", "minimal"):
        mode = "minimal"
    rows = _fetch_concerts_from_db()
    list_val = json.dumps(rows, default=str, ensure_ascii=False)
    list_ttl = int(CONCERTS_LIST_CACHE_TTL_SEC)
    if list_ttl > 0:
        redis_client.set(CONCERTS_LIST_KEY, list_val, ex=list_ttl)
    else:
        redis_client.set(CONCERTS_LIST_KEY, list_val)
    n_detail = 0
    if mode == "full":
        for r in rows:
            cid = int(r["concert_id"])
            d = build_concert_detail_api_dict(cid)
            if d:
                dv = json.dumps(d, default=str, ensure_ascii=False)
                dt = int(CONCERT_DETAIL_CACHE_TTL_SEC)
                dk = _concert_detail_key(cid)
                if dt > 0:
                    redis_client.set(dk, dv, ex=dt)
                else:
                    redis_client.set(dk, dv)
                n_detail += 1
    return {
        "name": "concert_read",
        "warmup_mode": mode,
        "list_key": CONCERTS_LIST_KEY,
        "concert_count": len(rows),
        "detail_keys": n_detail,
        "bootstrap_keys": 0,
        "shows_meta_ttl_sec": CONCERT_SHOWS_META_TTL_SEC,
        "show_snapshot_ttl_sec": CONCERT_SHOW_SNAPSHOT_TTL_SEC,
        "show_snapshot_ttl_jitter_pct": CONCERT_SHOW_SNAPSHOT_TTL_JITTER_PCT,
        "note": "invalidation on booking: show snapshot only; list/detail not flushed per ticket",
    }


def invalidate_concert_caches_after_booking(concert_id: int, show_id: Optional[int] = None) -> None:
    """
    예매/환불 후: **해당 회차 스냅샷**만 삭제(대량 티켓팅 시 전역 목록/상세 키를 지우지 않음).
    레거시 공연 단위 부트스트랩 키가 남아 있으면 함께 제거.
    공연 메타(제목 등)를 바꾼 뒤 즉시 반영하려면 관리용 전체 리빌드 또는 별도 무효화가 필요하다.
    """
    keys: List[str] = [_concert_bootstrap_key(concert_id)]
    sid = int(show_id or 0)
    if sid > 0:
        keys.append(_concert_show_snapshot_key(sid))
    try:
        redis_client.delete(*keys)
    except Exception:
        pass


def invalidate_concert_catalog_caches(concert_id: int) -> None:
    """공연 메타·회차 목록 캐시까지 비울 때(관리/배포용). 일반 예매 경로에서는 호출하지 않는다."""
    keys: List[str] = [
        CONCERTS_LIST_KEY,
        _concert_detail_key(concert_id),
        _concert_bootstrap_key(concert_id),
        _concert_shows_meta_key(concert_id),
    ]
    try:
        redis_client.delete(*keys)
    except Exception:
        pass
