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


def _make_pool(cursor):
    pool = MagicMock()
    conn = MagicMock()
    conn.cursor = MagicMock(return_value=AsyncCM(cursor))
    pool.acquire = MagicMock(return_value=AsyncCM(conn))
    return pool


@pytest.fixture
def mock_writer_pool(mock_cursor):
    return _make_pool(mock_cursor)


@pytest.fixture
def mock_reader_pool(mock_cursor):
    return _make_pool(mock_cursor)


@pytest.fixture
def mock_redis():
    r = MagicMock()
    r.get = AsyncMock(return_value=None)
    r.set = AsyncMock(return_value=True)
    r.setex = AsyncMock()
    r.delete = AsyncMock()
    r.decrby = AsyncMock(return_value=10)
    r.incrby = AsyncMock()
    return r


@pytest.fixture
def mock_sqs():
    return MagicMock()


@pytest.fixture
def client(mock_writer_pool, mock_reader_pool, mock_redis, mock_sqs, monkeypatch):
    import main
    monkeypatch.setattr(main, "writer_pool", mock_writer_pool)
    monkeypatch.setattr(main, "reader_pool", mock_reader_pool)
    monkeypatch.setattr(main, "redis_client", mock_redis)
    monkeypatch.setattr(main, "sqs_client", mock_sqs)
    monkeypatch.setattr(main, "SQS_URL", "https://sqs.test/queue")
    return TestClient(main.app)
