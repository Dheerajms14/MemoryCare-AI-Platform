"""Integration checks: local queue, retries, atomic batch, and role isolation."""
import os
import sqlite3
import tempfile
from uuid import uuid4

from fastapi.testclient import TestClient


temporary = tempfile.TemporaryDirectory()
os.environ["DATABASE_URL"] = "sqlite:///" + temporary.name + "/server.db"
os.environ["DEMO_SECRET"] = "test-secret-not-for-deployment"

from app.main import app  # noqa: E402


def sign_in(client: TestClient, role: str) -> str:
    response = client.post(
        "/auth/login", json={"username": role, "password": "demo1234"}
    )
    assert response.status_code == 200
    return response.json()["access_token"]


def test_offline_batch_replay_and_caregiver_visibility():
    with TestClient(app) as client:
        patient = sign_in(client, "patient")
        caregiver = sign_in(client, "caregiver")
        # Device is offline: only the local database sees its new operation.
        local = sqlite3.connect(":memory:")
        local.execute(
            "CREATE TABLE outbox (op_id TEXT PRIMARY KEY, kind TEXT, payload TEXT)"
        )
        item_id = str(uuid4())
        op_id = str(uuid4())
        payload = {
            "id": item_id,
            "title": "Offline medicine reminder",
            "due_at": "2026-09-22T11:00:00",
            "done": False,
        }
        import json
        local.execute(
            "INSERT INTO outbox VALUES (?, ?, ?)",
            (op_id, "reminder", json.dumps(payload)),
        )
        local.commit()
        before = client.get(
            "/caregiver/summary", headers={"Authorization": "Bearer " + caregiver}
        ).json()
        assert not any(r["title"] == payload["title"] for r in before["reminders"])

        operation = {"id": op_id, "kind": "reminder", "payload": payload}
        headers = {"Authorization": "Bearer " + patient}
        result = client.post("/sync", json={"operations": [operation]}, headers=headers)
        assert result.status_code == 200
        assert result.json()["acknowledged"] == [op_id]
        # Response lost after commit: retrying the SAME operation does not duplicate data.
        replay = client.post("/sync", json={"operations": [operation]}, headers=headers)
        assert replay.status_code == 200
        assert replay.json()["acknowledged"] == [op_id]
        local.execute("DELETE FROM outbox WHERE op_id = ?", (op_id,))
        local.commit()
        assert local.execute("SELECT count(*) FROM outbox").fetchone()[0] == 0
        after = client.get(
            "/caregiver/summary", headers={"Authorization": "Bearer " + caregiver}
        ).json()
        assert sum(r["title"] == payload["title"] for r in after["reminders"]) == 1
        assert client.get("/caregiver/summary", headers=headers).status_code == 403
        local.close()


def test_invalid_batch_rolls_back_and_outbox_can_retry():
    with TestClient(app) as client:
        patient = sign_in(client, "patient")
        caregiver = sign_in(client, "caregiver")
        title = "Batch rollback " + str(uuid4())
        ok = {
            "id": str(uuid4()),
            "kind": "reminder",
            "payload": {
                "id": str(uuid4()), "title": title,
                "due_at": "2026-09-22T11:00:00", "done": False,
            },
        }
        bad = {
            "id": str(uuid4()),
            "kind": "game",
            "payload": {
                "id": str(uuid4()), "game_type": "memory", "correct": 3,
                "total": 1, "seconds": 8, "played_at": "2026-09-22T11:00:00",
            },
        }
        failed = client.post(
            "/sync", json={"operations": [ok, bad]},
            headers={"Authorization": "Bearer " + patient},
        )
        assert failed.status_code == 422
        summary = client.get(
            "/caregiver/summary", headers={"Authorization": "Bearer " + caregiver}
        ).json()
        assert not any(r["title"] == title for r in summary["reminders"])
        retried = client.post(
            "/sync", json={"operations": [ok]},
            headers={"Authorization": "Bearer " + patient},
        )
        assert retried.status_code == 200
        assert retried.json()["acknowledged"] == [ok["id"]]
