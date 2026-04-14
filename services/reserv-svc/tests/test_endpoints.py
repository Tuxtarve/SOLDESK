import json


def test_health_ok(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "service": "reserv-svc"}


def test_create_reservation_missing_fields(client):
    res = client.post("/api/reservations", json={"eventId": "evt-1"})
    assert res.status_code == 400
    assert "필수 파라미터" in json.loads(res.content)["error"]


def test_create_reservation_success(client, mock_redis, mock_sqs):
    mock_redis.set.return_value = True
    mock_redis.decrby.return_value = 8
    res = client.post(
        "/api/reservations",
        json={"eventId": "evt-1", "seatIds": ["s1", "s2"], "userId": "u@test"},
    )
    assert res.status_code == 202
    body = json.loads(res.content)
    assert body["status"] == "PENDING"
    assert "reservationId" in body
    mock_sqs.send_message.assert_called_once()


def test_create_reservation_seat_locked(client, mock_redis):
    mock_redis.set.return_value = False  # 락 획득 실패
    res = client.post(
        "/api/reservations",
        json={"eventId": "evt-1", "seatIds": ["s1"], "userId": "u@test"},
    )
    assert res.status_code == 409
    assert "다른 사용자" in json.loads(res.content)["error"]


def test_create_reservation_sold_out(client, mock_redis):
    mock_redis.set.return_value = True
    mock_redis.decrby.return_value = -1  # 재고 부족
    res = client.post(
        "/api/reservations",
        json={"eventId": "evt-1", "seatIds": ["s1"], "userId": "u@test"},
    )
    assert res.status_code == 409
    assert "잔여 좌석" in json.loads(res.content)["error"]
    mock_redis.incrby.assert_called()


def test_get_reservation_not_found(client, mock_cursor):
    mock_cursor.fetchone.return_value = None
    res = client.get("/api/reservations/r-1", headers={"x-user-email": "u@test"})
    assert res.status_code == 404


def test_get_reservation_found(client, mock_cursor):
    mock_cursor.fetchone.return_value = {
        "id": "r-1",
        "user_id": "u@test",
        "event_id": "evt-1",
        "status": "CONFIRMED",
        "total_price": 100000,
        "created_at": None,
        "expires_at": None,
        "seat_ids": "s1,s2",
    }
    res = client.get("/api/reservations/r-1", headers={"x-user-email": "u@test"})
    assert res.status_code == 200
    assert res.json()["id"] == "r-1"


def test_list_reservations_unauthenticated(client):
    res = client.get("/api/reservations")
    assert res.status_code == 401


def test_payment_missing_id(client):
    res = client.post("/api/payments", json={"approved": True})
    assert res.status_code == 400


def test_payment_approved(client, mock_cursor):
    mock_cursor.fetchone.return_value = {
        "id": "r-1",
        "user_id": "u@test",
        "total_price": 50000,
        "status": "PENDING",
    }
    res = client.post(
        "/api/payments",
        json={"reservationId": "r-1", "approved": True},
        headers={"x-user-email": "u@test"},
    )
    assert res.status_code == 200
    assert res.json()["status"] == "CONFIRMED"


def test_payment_rejected(client, mock_cursor):
    mock_cursor.fetchone.return_value = {
        "id": "r-1",
        "user_id": "u@test",
        "total_price": 50000,
        "status": "PENDING",
    }
    res = client.post(
        "/api/payments",
        json={"reservationId": "r-1", "approved": False},
        headers={"x-user-email": "u@test"},
    )
    assert res.status_code == 200
    assert res.json()["status"] == "CANCELLED"


def test_payment_reservation_not_found(client, mock_cursor):
    mock_cursor.fetchone.return_value = None
    res = client.post(
        "/api/payments",
        json={"reservationId": "missing", "approved": True},
    )
    assert res.status_code == 404


def test_metrics_endpoint(client):
    res = client.get("/metrics")
    assert res.status_code == 200
    assert "reservation_requests_total" in res.text
