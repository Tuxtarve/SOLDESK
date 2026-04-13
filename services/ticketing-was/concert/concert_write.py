"""
콘서트 예매 쓰기 — SQS FIFO 통합 버전.
MessageGroupId=show_id-user_id 로 유저별 FIFO 파이프를 나눠, 동일 회차 대량 적체 시에도
다른 유저 요청이 한 그룹에 묶이지 않게 한다. 실제 좌석·잔여 정합성은 워커(DB)에서
좌석 유니크 + 원자적 잔여 UPDATE 로 처리한다.
"""
import json
import secrets
import string
import pymysql
from fastapi import APIRouter
from fastapi.responses import JSONResponse

from config import DB_HOST, DB_NAME, DB_PASSWORD, DB_PORT, DB_USER
from sqs_client import get_booking_status_dict, send_booking_message

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

    booking_ref = send_booking_message(
        booking_type="concert",
        group_id=f"{show_id}-{user_id}",
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
