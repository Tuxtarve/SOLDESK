import json


def test_healthz_ok(client):
    res = client.get("/healthz")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "service": "event-svc"}


def test_health_db_connected(client):
    res = client.get("/health")
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "ok"
    assert body["db"] == "connected"


def test_health_db_failure(client, mock_pool):
    mock_pool.acquire.side_effect = Exception("connection refused")
    res = client.get("/health")
    assert res.status_code == 503
    assert json.loads(res.content)["status"] == "error"


def test_list_events_from_db(client, mock_cursor, mock_redis):
    mock_cursor.fetchall.return_value = [
        {
            "id": "evt-1",
            "title": "콘서트",
            "venue": "홀",
            "start_at": None,
            "total_seats": 100,
            "available_seats": 50,
            "min_price": 30000,
            "status": "ON_SALE",
            "thumbnail_url": "https://example.com/t.jpg",
        }
    ]
    res = client.get("/api/events")
    assert res.status_code == 200
    rows = res.json()
    assert len(rows) == 1
    assert rows[0]["id"] == "evt-1"
    mock_redis.setex.assert_called_once()


def test_list_events_from_cache(client, mock_redis, mock_cursor):
    cached = [{"id": "evt-cached", "title": "캐시"}]
    mock_redis.get.return_value = json.dumps(cached)
    res = client.get("/api/events")
    assert res.status_code == 200
    assert res.json() == cached
    mock_cursor.execute.assert_not_called()


def test_get_seats_with_available_count(client, mock_cursor, mock_redis):
    mock_cursor.fetchall.return_value = [
        {"id": "s1", "section": "A", "row": "1", "number": 1, "grade": "VIP", "price": 100000, "status": "AVAILABLE"},
        {"id": "s2", "section": "A", "row": "1", "number": 2, "grade": "VIP", "price": 100000, "status": "RESERVED"},
    ]
    mock_redis.get.side_effect = [None, "42"]
    res = client.get("/api/events/evt-1/seats")
    assert res.status_code == 200
    body = res.json()
    assert body["eventId"] == "evt-1"
    assert body["availableCount"] == 42
    assert len(body["seats"]) == 2


def test_metrics_endpoint(client):
    res = client.get("/metrics")
    assert res.status_code == 200
    assert "event_svc_http_requests_total" in res.text
