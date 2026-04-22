"""
Auth write endpoints (Cognito 전환 후).

- 회원가입/비밀번호 관리는 Cognito가 처리하므로 제거.
- 프로필 수정은 미들웨어의 request.state.user_id 기반으로 동작.
"""
from typing import Any, Dict, Optional

from fastapi import APIRouter, Body, Request
from fastapi.responses import JSONResponse

from db import get_db_connection

router = APIRouter()


@router.post("/api/write/auth/edit")
def auth_edit_user(request: Request, payload: Optional[Dict[str, Any]] = Body(default=None)):
    """사용자 프로필 수정 (이름 + 전화번호). Cognito 미들웨어가 부착한 user_id 사용."""
    user_id = getattr(request.state, "user_id", None)
    if not user_id:
        return JSONResponse(status_code=401, content={"message": "인증이 필요합니다."})

    data = payload or {}
    name = (data.get("name") or "").strip()
    if not name:
        return JSONResponse(status_code=400, content={"message": "이름을 입력해 주세요."})

    # 전화번호는 optional. 프론트(edit.js) 가 숫자만 최대 11자리로 normalize 해서 보냄.
    # 비어있으면 NULL 저장(phone UNIQUE 제약 없음 — create.sql 에서 NULL 허용으로 둠).
    raw_phone = data.get("phone")
    phone = None
    if raw_phone is not None:
        cleaned = "".join(ch for ch in str(raw_phone) if ch.isdigit())
        phone = cleaned or None

    user_id_int = int(user_id)
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT user_id FROM users WHERE user_id = %s", (user_id_int,))
            if not cur.fetchone():
                return JSONResponse(status_code=404, content={"message": "사용자를 찾을 수 없습니다."})
            # phone 키가 payload 에 있으면 함께 업데이트, 없으면 이름만 업데이트(하위호환).
            if "phone" in data:
                cur.execute(
                    "UPDATE users SET name = %s, phone = %s WHERE user_id = %s",
                    (name, phone, user_id_int),
                )
            else:
                cur.execute(
                    "UPDATE users SET name = %s WHERE user_id = %s",
                    (name, user_id_int),
                )
        conn.commit()
        return {"message": "edit success", "success": True}
    finally:
        conn.close()
