"""Integration checks: local queue, retries, atomic batch, and role isolation."""
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient


from app.main import app  # noqa: E402


def sign_in(client: TestClient, role: str) -> str:
    registered = client.post('/auth/register', json={
        'username': role, 'password': 'Test only morning river 42!',
        'display_name': role.title(), 'role': role,
    })
    assert registered.status_code in {201, 409}
    response = client.post(
        "/auth/login", json={"username": role, "password": "Test only morning river 42!", "role": role}
    )
    assert response.status_code == 200
    if role == 'caregiver':
        patient = client.post('/auth/login', json={'username': 'patient', 'password': 'Test only morning river 42!'}).json()['access_token']
        code = client.post('/patients/invite', headers={'Authorization': 'Bearer ' + patient}).json()['code']
        assert client.post('/caregiver/link', json={'code': code}, headers={'Authorization': 'Bearer ' + response.json()['access_token']}).status_code == 200
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


def test_offline_deletion_is_idempotent_and_visible_to_caregiver():
    with TestClient(app) as client:
        patient = sign_in(client, "patient")
        caregiver = sign_in(client, "caregiver")
        headers = {"Authorization": "Bearer " + patient}
        reminder_id = str(uuid4())
        create = {
            "id": str(uuid4()),
            "kind": "reminder",
            "payload": {
                "id": reminder_id,
                "title": "Delete me after reconnecting",
                "due_at": "2026-09-29T12:30:00",
                "done": False,
                "reminder_type": "medicine",
                "language_code": "en",
                "voice_text": "Please take your medicine",
            },
        }
        assert client.post("/sync", json={"operations": [create]}, headers=headers).status_code == 200
        delete = {
            "id": str(uuid4()),
            "kind": "delete_reminder",
            "payload": {"id": reminder_id},
        }
        first = client.post("/sync", json={"operations": [delete]}, headers=headers)
        replay = client.post("/sync", json={"operations": [delete]}, headers=headers)
        assert first.status_code == replay.status_code == 200
        summary = client.get(
            "/caregiver/summary", headers={"Authorization": "Bearer " + caregiver}
        ).json()
        assert not any(row["id"] == reminder_id for row in summary["reminders"])


def test_memory_photo_upload_is_linked_to_caregiver_summary():
    with TestClient(app) as client:
        patient = sign_in(client, "patient")
        caregiver = sign_in(client, "caregiver")
        headers = {"Authorization": "Bearer " + patient}
        memory_id = str(uuid4())
        operation = {
            "id": str(uuid4()),
            "kind": "memory",
            "payload": {
                "id": memory_id,
                "person_name": "Asha",
                "relationship": "Daughter",
                "note": "Birthday celebration",
                "language_code": "en",
            },
        }
        assert client.post("/sync", json={"operations": [operation]}, headers=headers).status_code == 200
        uploaded = client.post(
            f"/memories/{memory_id}/media/photo",
            headers=headers,
            files={"file": ("asha.jpg", b"demo-jpeg-bytes", "image/jpeg")},
        )
        assert uploaded.status_code == 200
        summary = client.get(
            "/caregiver/summary", headers={"Authorization": "Bearer " + caregiver}
        ).json()
        row = next(item for item in summary["memories"] if item["id"] == memory_id)
        assert row["photo_url"].startswith("/media/")
