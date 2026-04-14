def test_health_ok(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "service": "worker-svc"}


def test_metrics_endpoint(client):
    res = client.get("/metrics")
    assert res.status_code == 200
    assert "worker_processed_total" in res.text


def test_worker_metrics_alias(client):
    res = client.get("/worker-metrics")
    assert res.status_code == 200
