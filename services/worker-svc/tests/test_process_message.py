import json


def _make_msg(reservation_id="r-1", seat_ids=None, lock_keys=None):
    return {
        "ReceiptHandle": "receipt-abc",
        "Body": json.dumps({
            "reservationId": reservation_id,
            "userId": "u@test",
            "eventId": "evt-1",
            "seatIds": seat_ids or ["s1", "s2"],
            "expiresAt": "2026-04-14T10:00:00+00:00",
            "lockKeys": lock_keys or ["seat:lock:evt-1:s1", "seat:lock:evt-1:s2"],
        }),
    }


async def test_process_message_success(patched_main, mock_cursor, mock_redis, mock_conn):
    mock_cursor.fetchall.return_value = [("s1", 50000), ("s2", 50000)]

    await patched_main.process_message(_make_msg())

    mock_conn.begin.assert_awaited_once()
    mock_conn.commit.assert_awaited_once()
    mock_conn.rollback.assert_not_called()
    # 2개 락 키 모두 삭제 + receipt 삭제
    assert mock_redis.delete.await_count == 2


async def test_process_message_seat_conflict_rolls_back(patched_main, mock_cursor, mock_conn):
    # seat_ids는 2개 요청했는데 1개만 AVAILABLE → 충돌
    mock_cursor.fetchall.return_value = [("s1", 50000)]

    await patched_main.process_message(_make_msg())

    mock_conn.rollback.assert_awaited_once()
    mock_conn.commit.assert_not_called()


async def test_process_message_db_error_rolls_back(patched_main, mock_cursor, mock_conn):
    mock_cursor.fetchall.return_value = [("s1", 50000), ("s2", 50000)]
    # INSERT 단계에서 예외
    mock_cursor.execute.side_effect = [None, Exception("dup key"), None]

    await patched_main.process_message(_make_msg())

    mock_conn.rollback.assert_awaited()
    mock_conn.commit.assert_not_called()


async def test_process_message_deletes_sqs_receipt(patched_main, mock_cursor, mock_sqs):
    mock_cursor.fetchall.return_value = [("s1", 50000), ("s2", 50000)]

    await patched_main.process_message(_make_msg())

    mock_sqs.delete_message.assert_called_once()
    kwargs = mock_sqs.delete_message.call_args.kwargs
    assert kwargs["ReceiptHandle"] == "receipt-abc"
