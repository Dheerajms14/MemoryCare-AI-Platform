"""Python-only demonstration of the SAME API and durable outbox as the Flutter app.

Usage:
    python pc_demo/offline_demo.py init
    python pc_demo/offline_demo.py offline
    python pc_demo/offline_demo.py show
    python pc_demo/offline_demo.py sync
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
from getpass import getpass
from pathlib import Path
import sqlite3
from urllib import request
from urllib.error import HTTPError, URLError
from uuid import uuid4


DEFAULT_DB = Path(__file__).parent / "data" / "device.db"


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS local_items
          (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS outbox
          (seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT UNIQUE NOT NULL,
           kind TEXT NOT NULL, payload_json TEXT NOT NULL);
        """
    )
    return db


def post(api: str, route: str, data: dict, token: str | None = None) -> dict:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = request.Request(
        api.rstrip("/") + route,
        data=json.dumps(data).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with request.urlopen(req, timeout=5) as result:
        return json.load(result)


def login(db: sqlite3.Connection, api: str, username: str | None = None) -> str:
    saved = db.execute("SELECT value FROM settings WHERE key = 'username'").fetchone()
    username = username or (saved['value'] if saved else input('Patient username: ').strip())
    reply = post(api, "/auth/login", {"username": username, "password": getpass('Patient passphrase: '), "role": "patient"})
    if reply["role"] != "patient":
        raise ValueError("Patient account required")
    owner = db.execute("SELECT value FROM settings WHERE key = 'user_id'").fetchone()
    # Recover ONLY an ownership hint from the previous local token; never use
    # it for authentication. The API still verifies the new login normally.
    legacy = db.execute("SELECT value FROM settings WHERE key = 'access_token'").fetchone()
    old_id = owner['value'] if owner else None
    if old_id is None and legacy:
        try:
            encoded = legacy['value'].split('.')[0]
            old_id = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))['sub']
        except (ValueError, KeyError, TypeError):
            raise ValueError('Cannot establish the owner of the old offline data. Preserve the database and check the original account.') from None
    if old_id is not None and old_id != reply['user_id']:
        post(api, '/auth/logout', {}, reply['access_token'])
        raise ValueError('This database contains another patient\'s data. Use its original account.')
    if old_id is None and db.execute('SELECT count(*) FROM local_items').fetchone()[0]:
        post(api, '/auth/logout', {}, reply['access_token'])
        raise ValueError('Existing offline records have no verified account binding. Do not send them to a new patient.')
    with db:
        db.execute("DELETE FROM settings WHERE key = 'access_token'")
        db.executemany('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)',
                       [('user_id', reply['user_id']), ('username', reply['username'])])
    return reply['access_token']  # CLI tokens stay in memory; never in SQLite.


def add_item(db: sqlite3.Connection, kind: str, payload: dict) -> None:
    wire = json.dumps(payload)
    # Store readable local data and its pending network operation atomically.
    db.execute(
        "INSERT INTO local_items (id, kind, payload_json) VALUES (?, ?, ?)",
        (payload["id"], kind, wire),
    )
    db.execute(
        "INSERT INTO outbox (op_id, kind, payload_json) VALUES (?, ?, ?)",
        (str(uuid4()), kind, wire),
    )


def create_offline(db: sqlite3.Connection) -> None:
    if db.execute("SELECT value FROM settings WHERE key = 'user_id'").fetchone() is None:
        raise ValueError("Run init while online before the first offline use")
    now = datetime.now(timezone.utc)
    with db:
        add_item(
            db,
            "reminder",
            {
                "id": str(uuid4()), "title": "Take morning medicine",
                "due_at": (now + timedelta(hours=1)).isoformat(), "done": False,
            },
        )
        add_item(
            db,
            "memory",
            {
                "id": str(uuid4()), "person_name": "Asha",
                "relationship": "Daughter", "note": "We visit the park together.",
            },
        )
        add_item(
            db,
            "game",
            {
                "id": str(uuid4()), "game_type": "memory",
                "correct": 1, "total": 1, "seconds": 14,
                "played_at": now.isoformat(),
            },
        )
    print("OFFLINE: saved a reminder, a memory note, and a game result in local SQLite.")
    show(db)


def show(db: sqlite3.Connection) -> None:
    total = db.execute("SELECT count(*) FROM local_items").fetchone()[0]
    rows = db.execute("SELECT seq, kind, payload_json FROM outbox ORDER BY seq").fetchall()
    print(f"Local items: {total}; pending uploads: {len(rows)}")
    for row in rows:
        data = json.loads(row["payload_json"])
        label = data.get("title") or data.get("person_name") or data.get("game_type")
        print(f"  #{row['seq']} {row['kind']}: {label}")


def sync(db: sqlite3.Connection, api: str, username: str | None = None) -> None:
    owner = db.execute("SELECT value FROM settings WHERE key IN ('user_id','access_token')").fetchone()
    if owner is None:
        raise ValueError("Run init while online first")
    if db.execute('SELECT count(*) FROM outbox').fetchone()[0] == 0:
        print('SYNC COMPLETE: pending uploads = 0.')
        return
    token = login(db, api, username)
    while True:
        rows = db.execute(
            "SELECT op_id, kind, payload_json FROM outbox ORDER BY seq LIMIT 25"
        ).fetchall()
        if not rows:
            post(api, '/auth/logout', {}, token)
            print("SYNC COMPLETE: pending uploads = 0. Refresh the caregiver dashboard.")
            return
        expected = {row["op_id"] for row in rows}
        response = post(
            api,
            "/sync",
            {"operations": [
                {
                    "id": row["op_id"], "kind": row["kind"],
                    "payload": json.loads(row["payload_json"]),
                }
                for row in rows
            ]},
            token,
        )
        acknowledged = response["acknowledged"]
        if len(acknowledged) != len(rows) or set(acknowledged) != expected:
            raise ValueError("Server did not acknowledge the entire batch; outbox retained")
        with db:
            db.executemany(
                "DELETE FROM outbox WHERE op_id = ?",
                [(op_id,) for op_id in acknowledged],
            )
        print(f"Server committed {len(acknowledged)} changes; deleted only acknowledged outbox rows.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Repeatable offline → reconnect → sync demo")
    parser.add_argument("command", choices=["init", "offline", "show", "sync"])
    parser.add_argument("--api", default="http://127.0.0.1:8000")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--username", help="Registered patient username (password is requested privately)")
    args = parser.parse_args()
    with connect(args.db) as db:
        try:
            if args.command == "init":
                token = login(db, args.api, args.username)
                post(args.api, '/auth/logout', {}, token)
                print('Account verified. You may now stop the server and create offline records. No token was saved in SQLite.')
            elif args.command == "offline":
                create_offline(db)
            elif args.command == "show":
                show(db)
            else:
                sync(db, args.api, args.username)
        except (URLError, HTTPError, TimeoutError) as exc:
            print(f"Network unavailable or server rejected request: {exc}. Local queue retained.")
            return 1
        except ValueError as exc:
            print(f"Error: {exc}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
