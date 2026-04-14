import sys
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class AsyncCM:
    def __init__(self, value):
        self.value = value

    async def __aenter__(self):
        return self.value

    async def __aexit__(self, *_):
        return None


@pytest.fixture
def mock_cursor():
    cur = MagicMock()
    cur.execute = AsyncMock()
    cur.fetchall = AsyncMock(return_value=[])
    cur.fetchone = AsyncMock(return_value=None)
    return cur


@pytest.fixture
def mock_conn(mock_cursor):
    conn = MagicMock()
    conn.cursor = MagicMock(return_value=AsyncCM(mock_cursor))
    conn.begin = AsyncMock()
    conn.commit = AsyncMock()
    conn.rollback = AsyncMock()
    return conn


@pytest.fixture
def mock_writer_pool(mock_conn):
    pool = MagicMock()
    pool.acquire = MagicMock(return_value=AsyncCM(mock_conn))
    return pool


@pytest.fixture
def mock_redis():
    r = MagicMock()
    r.delete = AsyncMock()
    return r


@pytest.fixture
def mock_sqs():
    return MagicMock()


@pytest.fixture
def patched_main(mock_writer_pool, mock_redis, mock_sqs, monkeypatch):
    import main
    monkeypatch.setattr(main, "writer_pool", mock_writer_pool)
    monkeypatch.setattr(main, "redis_client", mock_redis)
    monkeypatch.setattr(main, "sqs_client", mock_sqs)
    monkeypatch.setattr(main, "SQS_URL", "https://sqs.test/queue")
    return main


@pytest.fixture
def client(patched_main):
    return TestClient(patched_main.app)
