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
def mock_pool(mock_cursor):
    pool = MagicMock()
    conn = MagicMock()
    conn.cursor = MagicMock(return_value=AsyncCM(mock_cursor))
    pool.acquire = MagicMock(return_value=AsyncCM(conn))
    return pool


@pytest.fixture
def mock_redis():
    r = MagicMock()
    r.get = AsyncMock(return_value=None)
    r.setex = AsyncMock()
    return r


@pytest.fixture
def client(mock_pool, mock_redis, monkeypatch):
    import main
    monkeypatch.setattr(main, "reader_pool", mock_pool)
    monkeypatch.setattr(main, "redis_client", mock_redis)
    return TestClient(main.app)
