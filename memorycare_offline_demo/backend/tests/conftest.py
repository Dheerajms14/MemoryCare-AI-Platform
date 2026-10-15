"""Every test uses a temporary database, never the user's demo data."""
import os
import sys
import tempfile
from pathlib import Path

import pytest

temporary = tempfile.TemporaryDirectory()
os.environ["DATABASE_URL"] = "sqlite:///" + temporary.name + "/server.db"
os.environ["AUTH_SECRET_KEY"] = "test-only-secret-" * 4
os.environ["APP_ENV"] = "development"
os.environ["PUBLIC_ORIGIN"] = ""
os.environ["MEDIA_DIR"] = temporary.name + "/media"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base, engine  # noqa: E402


@pytest.fixture(autouse=True)
def client():
    with TestClient(app) as test_client:
        with engine.begin() as connection:
            for table in reversed(Base.metadata.sorted_tables):
                connection.execute(table.delete())
        yield test_client
