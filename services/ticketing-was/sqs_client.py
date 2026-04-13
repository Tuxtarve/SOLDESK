"""
AWS SQS FIFO + Amazon ElastiCache 예매 쓰기 (write-api ↔ worker-svc, 동일 VPC)

1) 커밋(POST, write-api)
   - `booking_ref`(UUID) 발급 후 메시지 본문에 넣어 **SQS FIFO** 로 전송 (완전 관리형, 리전 내부).
   - MessageGroupId = schedule_id-user_id / show_id-user_id → 유저별 순서·타 유저와는 병렬(좌석은 워커 DB 락).
   - 전송 성공 직후 **ElastiCache 논리 DB `ELASTICACHE_LOGICAL_DB_BOOKING`** 에 `booking:queued:{ref}` (TTL).

2) 처리(worker-svc)
   - **RDS** 트랜잭션 후 동일 booking 논리 DB에 `booking:result:{ref}` (setex), queued 키 삭제.

3) 폴링(GET)
   - result → 최종 JSON; queued만 있으면 PROCESSING; 둘 다 없으면 UNKNOWN_OR_EXPIRED.

4) 비용·격리
   - ElastiCache는 **단일 소형 노드** 유지, 조회 캐시와 예매 상태는 **논리 DB 분리**
     → admin 조회 캐시 FLUSHDB 가 booking:* 를 지우지 않음 (노드 추가 비용 없음).

5) 한계
   - DB 커밋 후·결과 기록 전 장애 시 재전달 이중 시도 가능 → 장기적으로 booking_ref DB 유니크 등 권장.
"""
from __future__ import annotations

import hashlib
import json
import logging
import uuid

import boto3
from botocore.config import Config

from config import (
    AWS_REGION,
    BOOKING_QUEUED_TTL_SEC,
    BOOKING_STATE_ENABLED,
    SQS_BOTO_MAX_ATTEMPTS,
    SQS_BOTO_RETRY_MODE,
    SQS_CONNECT_TIMEOUT_SEC,
    SQS_ENABLED,
    SQS_QUEUE_URL,
    SQS_READ_TIMEOUT_SEC,
)

log = logging.getLogger("sqs_client")


def _boto_config() -> Config:
    mode = (SQS_BOTO_RETRY_MODE or "adaptive").strip().lower()
    if mode not in ("standard", "adaptive"):
        mode = "standard"
    return Config(
        retries={"max_attempts": int(SQS_BOTO_MAX_ATTEMPTS), "mode": mode},
        connect_timeout=int(SQS_CONNECT_TIMEOUT_SEC),
        read_timeout=int(SQS_READ_TIMEOUT_SEC),
    )


sqs = (
    boto3.client("sqs", region_name=AWS_REGION, config=_boto_config())
    if (SQS_ENABLED and SQS_QUEUE_URL)
    else None
)


def _booking_result_key(booking_ref: str) -> str:
    return f"booking:result:{booking_ref}"


def _booking_queued_key(booking_ref: str) -> str:
    return f"booking:queued:{booking_ref}"


def _valid_booking_ref(booking_ref: str) -> bool:
    try:
        uuid.UUID(str(booking_ref).strip())
        return True
    except (ValueError, TypeError, AttributeError):
        return False


def _mark_booking_queued(booking_ref: str) -> None:
    if not BOOKING_STATE_ENABLED:
        return
    try:
        from cache.elasticache_booking_client import elasticache_booking_client

        elasticache_booking_client.setex(
            _booking_queued_key(booking_ref),
            int(BOOKING_QUEUED_TTL_SEC),
            "1",
        )
    except Exception:
        log.exception("booking queued 표식 실패 ref=%s (SQS 메시지는 이미 전송됨)", booking_ref)


def send_booking_message(
    booking_type: str,
    group_id: str,
    payload: dict,
    *,
    booking_ref: str | None = None,
) -> str:
    """
    SQS FIFO 큐에 예매 메시지 전송.
    - booking_type: "theater" 또는 "concert"
    - group_id: FIFO MessageGroupId (예: f"{show_id}-{user_id}")
    - payload: 예매 요청 데이터
    Returns: booking_ref (결과 조회용 UUID)
    """
    booking_ref = str(booking_ref).strip() if booking_ref else str(uuid.uuid4())
    if not _valid_booking_ref(booking_ref):
        booking_ref = str(uuid.uuid4())

    body = {
        "booking_type": booking_type,
        "booking_ref": booking_ref,
        **payload,
    }

    raw = json.dumps(body, sort_keys=True)
    dedup_id = hashlib.sha256(raw.encode()).hexdigest()

    if not SQS_ENABLED:
        raise RuntimeError("SQS is disabled (SQS_ENABLED=false). No sync DB fallback is configured.")
    if not sqs or not SQS_QUEUE_URL:
        raise RuntimeError("SQS_QUEUE_URL is required when SQS is enabled")

    sqs.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageGroupId=str(group_id),
        MessageDeduplicationId=dedup_id,
        MessageBody=raw,
    )
    log.info("SQS 전송: type=%s, group=%s, ref=%s", booking_type, group_id, booking_ref)
    _mark_booking_queued(booking_ref)
    return booking_ref


def get_booking_result(booking_ref: str):
    """ElastiCache(booking 논리 DB)에서 예매 처리 결과만 조회 (없으면 None)."""
    if not BOOKING_STATE_ENABLED:
        return None
    from cache.elasticache_booking_client import elasticache_booking_client

    data = elasticache_booking_client.get(_booking_result_key(booking_ref))
    if data:
        return json.loads(data)
    return None


def get_booking_status_dict(booking_ref: str) -> dict:
    """
    폴링용 통합 응답.
    - 최종 결과 dict → 그대로 반환(기존 클라이언트 호환).
    - PROCESSING / UNKNOWN_OR_EXPIRED / INVALID_REF 는 status 필드로 구분.
    """
    ref = str(booking_ref or "").strip()
    if not _valid_booking_ref(ref):
        return {"status": "INVALID_REF", "booking_ref": ref}

    result = get_booking_result(ref)
    if result is not None:
        return result

    if BOOKING_STATE_ENABLED:
        from cache.elasticache_booking_client import elasticache_booking_client

        try:
            if elasticache_booking_client.get(_booking_queued_key(ref)):
                return {"status": "PROCESSING", "booking_ref": ref}
        except Exception:
            log.exception("booking queued 조회 실패 ref=%s", ref)

    return {
        "status": "UNKNOWN_OR_EXPIRED",
        "booking_ref": ref,
        "message": "요청이 없거나 대기 TTL이 지났습니다. 새로 예매를 시도하세요.",
    }
