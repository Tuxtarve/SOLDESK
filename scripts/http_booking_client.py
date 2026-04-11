"""
Write API(유저 경로) — 극장/콘서트 예매 커밋 POST + 상태 GET 폴링.
표준 라이브러리만 사용 (urllib).

베이스 URL: WRITE_API_BASE_URL 또는 호출부에서 전달.
클러스터 내부 예: http://write-api.ticketing.svc.cluster.local:5001
"""
from __future__ import annotations

import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Literal

Kind = Literal["theater", "concert"]


def resolve_write_api_base(cli_base: str | None) -> str:
    b = (cli_base or "").strip() or (os.getenv("WRITE_API_BASE_URL") or "").strip()
    if not b:
        raise SystemExit(
            "Write API 베이스 URL 필요: --write-api-base 또는 환경변수 WRITE_API_BASE_URL\n"
            "  예: http://write-api.ticketing.svc.cluster.local:5001\n"
            "  주의: 노트북 셸에서 export 한 값은 kubectl exec ... sh -c '...' 안으로 자동 전달되지 않습니다.\n"
            "    exec 문자열 안에서 export 하거나: sh -c \"export WRITE_API_BASE_URL='$WRITE_API_BASE_URL' && ...\"\n"
            "    또는: --write-api-base http://write-api.ticketing.svc.cluster.local:5001"
        )
    return b.rstrip("/")


def _ssl_ctx() -> ssl.SSLContext:
    return ssl.create_default_context()


def request_json(
    url: str,
    method: str,
    body: dict | None,
    *,
    timeout: float,
) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method.upper())
    if body is not None:
        req.add_header("Content-Type", "application/json; charset=utf-8")
    ctx = None
    if urllib.parse.urlparse(url).scheme == "https":
        ctx = _ssl_ctx()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read().decode("utf-8")
            code = resp.getcode()
            if not raw.strip():
                return code, {}
            return code, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            return e.code, {"_parse_error": True, "_raw": raw, "_http_status": e.code}


def theater_commit(
    base: str,
    user_id: int,
    schedule_id: int,
    seats: list[str],
    *,
    timeout: float = 60.0,
) -> tuple[int, dict]:
    url = f"{base}/api/write/theaters/booking/commit"
    return request_json(
        url,
        "POST",
        {"user_id": user_id, "schedule_id": schedule_id, "seats": seats},
        timeout=timeout,
    )


def concert_commit(
    base: str,
    user_id: int,
    show_id: int,
    seats: list[str],
    *,
    timeout: float = 60.0,
) -> tuple[int, dict]:
    url = f"{base}/api/write/concerts/booking/commit"
    return request_json(
        url,
        "POST",
        {"user_id": user_id, "show_id": show_id, "seats": seats},
        timeout=timeout,
    )


def booking_status_get(base: str, booking_ref: str, kind: Kind, *, timeout: float = 30.0) -> tuple[int, dict]:
    ref = str(booking_ref).strip()
    if kind == "theater":
        url = f"{base}/api/write/booking/status/{ref}"
    else:
        url = f"{base}/api/write/concerts/booking/status/{ref}"
    return request_json(url, "GET", None, timeout=timeout)


def is_terminal_booking_status(j: dict) -> bool:
    if not isinstance(j, dict):
        return True
    st = j.get("status")
    if st == "PROCESSING":
        return False
    if st in ("UNKNOWN_OR_EXPIRED", "INVALID_REF"):
        return True
    if "ok" in j:
        return True
    return False


def poll_booking_status(
    base: str,
    booking_ref: str,
    kind: Kind,
    *,
    timeout_sec: float,
    interval_sec: float = 0.25,
) -> dict:
    deadline = time.monotonic() + timeout_sec
    last: dict = {}
    while time.monotonic() < deadline:
        _, last = booking_status_get(base, booking_ref, kind, timeout=min(30.0, timeout_sec))
        if is_terminal_booking_status(last):
            return last
        time.sleep(interval_sec)
    return last if last else {"status": "TIMEOUT", "booking_ref": booking_ref}
