"""Real local end-to-end check: server up -> down -> offline writes -> up -> sync."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib import request
from urllib.error import URLError


ROOT = Path(__file__).resolve().parents[1]
API_DIR = ROOT / "backend"
PC_SCRIPT = ROOT / "pc_demo" / "offline_demo.py"


def run_cli(command: str, api: str, db_path: Path, expected_code: int = 0) -> str:
    result = subprocess.run(
        [sys.executable, str(PC_SCRIPT), command, "--api", api, "--db", str(db_path)],
        text=True, capture_output=True, timeout=12, check=False,
    )
    assert result.returncode == expected_code, result.stdout + result.stderr
    print(result.stdout.strip())
    return result.stdout


def post(api: str, route: str, body: dict, token: str | None = None) -> dict:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = request.Request(
        api + route, method="POST", headers=headers, data=json.dumps(body).encode()
    )
    return json.load(request.urlopen(req, timeout=4))


def start_server(api: str, env: dict) -> subprocess.Popen:
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1",
         "--port", api.rsplit(":", 1)[1]],
        cwd=API_DIR, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(60):
        try:
            with request.urlopen(api + "/health", timeout=1):
                return proc
        except (URLError, TimeoutError):
            if proc.poll() is not None:
                raise RuntimeError("API exited during startup")
            time.sleep(0.1)
    proc.terminate()
    raise RuntimeError("API did not start within six seconds")


def stop_server(proc: subprocess.Popen) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)


def main() -> None:
    with tempfile.TemporaryDirectory() as folder:
        temp = Path(folder)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        api = "http://127.0.0.1:" + str(port)
        env = dict(os.environ)
        env["DATABASE_URL"] = "sqlite:///" + str(temp / "server.db")
        env["DEMO_SECRET"] = "only-for-integration-test"
        device_db = temp / "device.db"
        proc = start_server(api, env)
        try:
            run_cli("init", api, device_db)
            stop_server(proc)
            run_cli("offline", api, device_db)
            run_cli("sync", api, device_db, expected_code=1)
            with sqlite3.connect(device_db) as db:
                assert db.execute("SELECT count(*) FROM outbox").fetchone()[0] == 3
            proc = start_server(api, env)
            run_cli("sync", api, device_db)
            with sqlite3.connect(device_db) as db:
                assert db.execute("SELECT count(*) FROM outbox").fetchone()[0] == 0
                assert db.execute("SELECT count(*) FROM local_items").fetchone()[0] == 3
            caregiver = post(
                api, "/auth/login", {"username": "caregiver", "password": "demo1234"}
            )["access_token"]
            req = request.Request(
                api + "/caregiver/summary",
                headers={"Authorization": "Bearer " + caregiver},
            )
            summary = json.load(request.urlopen(req, timeout=4))
            assert len(summary["reminders"]) == 1
            assert len(summary["memories"]) == 1
            assert len(summary["games"]) == 1
            print("PASS: offline data survived restart and became visible after sync.")
        finally:
            if proc.poll() is None:
                stop_server(proc)


if __name__ == "__main__":
    main()
