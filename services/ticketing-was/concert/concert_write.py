"""
콘서트 예매 쓰기 — SQS FIFO 통합 버전.
원본: _ShowLockPool(threading.Lock) → SQS FIFO MessageGroupId=show_id.
      유저별 그룹(show_id-user_id)으로 분리해 동일 회차라도 타 유저 대량 적체에 GUI 예매가 묻히지 않게 함(DB는 FOR UPDATE 로 좌석 정합성 유지).
"""
import json
import uuid
import secrets
import string
import pymysql
from fastapi import APIRouter
from fastapi.responses import JSONResponse

from config import DB_HOST, DB_NAME, DB_PASSWORD, DB_PORT, DB_USER
from sqs_client import get_booking_status_dict, send_booking_message
from concert.sale_state import get_sale_state, is_open, set_sale_state
from concert.seat_hold import try_hold_seats

router = APIRouter()

# NOTE: Local synchronous fallback removed (EKS-only).


def _to_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse_seat_key(value: str):
    text = str(value or "").strip()
    parts = text.split("-")
    if len(parts) != 2:
        return None
    row = _to_int(parts[0])
    col = _to_int(parts[1])
    if row <= 0 or col <= 0:
        return None
    return row, col


def _get_tx_connection():
    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )


def _is_duplicate_key_error(exc: Exception) -> bool:
    if not isinstance(exc, pymysql.err.IntegrityError):
        return False
    try:
        return int(exc.args[0]) == 1062
    except Exception:
        return False


def _generate_booking_code() -> str:
    letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(2))
    digits = "".join(secrets.choice(string.digits) for _ in range(6))
    return f"C{letters}{digits}"


def _seat_shard_id(row: int, col: int) -> int:
    """
    한 회차 내부 샤딩(병렬 처리 데모/운영용).
    - FIFO MessageGroupId를 show_id 단일이 아니라 show_id+shard로 쪼개면
      같은 회차라도 서로 다른 shard는 병렬 처리 가능(파드 확장 효과가 큼).
    - 샤드 수는 환경변수로 조절(기본 64).
    """
    try:
        n = int((__import__("os").getenv("CONCERT_FIFO_SHARDS", "64") or "64").strip())
    except Exception:
        n = 64
    n = max(1, min(1024, n))
    # 좌석 좌표 기반의 간단한 해시(빠르고 분산 충분)
    return ((int(row) * 1000003) ^ int(col)) % n


@router.post("/api/write/concerts/booking/commit")
def commit_concert_booking(payload: dict):
    data = payload if isinstance(payload, dict) else {}
    user_id = _to_int(data.get("user_id"))
    show_id = _to_int(data.get("show_id"))
    seats = data.get("seats") or []

    if user_id <= 0 or show_id <= 0:
        return JSONResponse(
            status_code=400,
            content={"ok": False, "code": "BAD_REQUEST", "message": "요청값이 올바르지 않습니다."},
        )

    if not isinstance(seats, list) or not seats:
        return JSONResponse(
            status_code=400,
            content={"ok": False, "code": "NO_SEATS", "message": "좌석을 선택해주세요."},
        )

    parsed_seats = []
    seat_set = set()
    for item in seats:
        parsed = _parse_seat_key(item)
        if not parsed:
            return JSONResponse(
                status_code=400,
                content={"ok": False, "code": "BAD_SEAT_KEY", "message": "좌석 형식이 올바르지 않습니다."},
            )
        if parsed in seat_set:
            continue
        seat_set.add(parsed)
        parsed_seats.append(parsed)

    req_count = len(parsed_seats)
    if req_count <= 0:
        return JSONResponse(
            status_code=400,
            content={"ok": False, "code": "NO_SEATS", "message": "좌석을 선택해주세요."},
        )

    # 실서비스 UX: 마감 상태면 즉시 컷(백그라운드 처리량/큐 적체와 무관하게 화면은 '땡'에 끊긴다)
    if not is_open(show_id):
        st = get_sale_state(show_id)
        return JSONResponse(
            status_code=409,
            content={
                "ok": False,
                "code": "SALES_CLOSED",
                "message": "모든 투표가 마감되었습니다.",
                "sale": st,
            },
        )

    # booking_ref를 write-api에서 먼저 발급해 Redis 홀드 ↔ SQS 메시지 ↔ 폴링 키를 하나로 묶는다.
    booking_ref = str(uuid.uuid4())

    # 확정(=접수) 난 만큼 즉시 remain에 반영: SQS 전송 전에 Redis에서 좌석을 먼저 홀드한다.
    hold = try_hold_seats(show_id=show_id, seats=parsed_seats, booking_ref=booking_ref)
    if not hold.get("ok"):
        return JSONResponse(status_code=409, content={"ok": False, "code": hold.get("code") or "DUPLICATE_SEAT"})

    booking_ref = send_booking_message(
        booking_type="concert",
        group_id=f"{show_id}-sh{_seat_shard_id(parsed_seats[0][0], parsed_seats[0][1])}",
        booking_ref=booking_ref,
        payload={
            "user_id": user_id,
            "show_id": show_id,
            "seats": [f"{r}-{c}" for r, c in parsed_seats],
        },
    )
    return {
        "ok": True,
        "code": "QUEUED",
        "booking_ref": booking_ref,
        "message": "예매 요청이 접수되었습니다.",
    }


@router.get("/api/write/concerts/booking/status/{booking_ref}")
def check_concert_booking_status(booking_ref: str):
    return get_booking_status_dict(booking_ref)


# --- 판매 상태 제어(운영/데모용) ---
@router.get("/api/write/concerts/{show_id}/sale")
def get_concert_sale(show_id: int):
    return {"ok": True, "show_id": int(show_id), "sale": get_sale_state(int(show_id))}


@router.post("/api/write/concerts/{show_id}/sale/open")
def open_concert_sale(show_id: int):
    set_sale_state(int(show_id), "OPEN")
    return {"ok": True, "show_id": int(show_id), "sale": get_sale_state(int(show_id))}


@router.post("/api/write/concerts/{show_id}/sale/close")
def close_concert_sale(show_id: int):
    set_sale_state(int(show_id), "CLOSED")
    return {"ok": True, "show_id": int(show_id), "sale": get_sale_state(int(show_id))}
