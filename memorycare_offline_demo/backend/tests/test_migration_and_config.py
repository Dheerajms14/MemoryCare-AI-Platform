"""Legacy database migration/operator reset and fail-closed deployment checks."""
import json
import os
from pathlib import Path
import secrets
import sqlite3
import subprocess
import sys

from fastapi.testclient import TestClient

from app import config
from app.main import app

BACKEND = Path(__file__).resolve().parents[1]


def test_real_old_schema_migrates_and_password_reset_keeps_records(tmp_path):
    path = tmp_path / 'old.db'
    with sqlite3.connect(path) as db:
        db.executescript('''
            CREATE TABLE accounts(id VARCHAR(80) PRIMARY KEY, username VARCHAR(80) UNIQUE,
                password_hash VARCHAR(200), role VARCHAR(20), patient_id VARCHAR(80));
            CREATE TABLE reminders(id VARCHAR(80) PRIMARY KEY, patient_id VARCHAR(80),
                title VARCHAR(160), due_at VARCHAR(40), done BOOLEAN);
            INSERT INTO accounts VALUES ('patient-1','patient','legacy-demo-hash','patient',NULL);
            INSERT INTO reminders VALUES ('old-reminder','patient-1','Keep this record','2026-10-01T12:00:00',0);
        ''')
    env = {**os.environ, 'DATABASE_URL': 'sqlite:///' + str(path),
           'MEDIA_DIR': str(tmp_path / 'media'), 'AUTH_SECRET_KEY': secrets.token_urlsafe(48),
           'APP_ENV': 'development', 'PUBLIC_ORIGIN': ''}
    start = subprocess.run([sys.executable, '-c',
        'from fastapi.testclient import TestClient; from app.main import app; '
        '\nwith TestClient(app) as c: print(c.get("/health").status_code)'],
        cwd=BACKEND, env=env, text=True, capture_output=True, timeout=30)
    assert start.returncode == 0, start.stderr
    with sqlite3.connect(path) as db:
        assert db.execute('SELECT id,is_active FROM accounts').fetchone() == ('patient-1', 0)
        assert db.execute('SELECT title,language_code FROM reminders').fetchone() == ('Keep this record', 'en')
    password = 'Operator test only morning river 64!'
    reset = subprocess.run([sys.executable, '-m', 'app.manage_accounts', '--username', 'patient'],
        cwd=BACKEND, env=env, input=password + '\n' + password + '\n',
        text=True, capture_output=True, timeout=30)
    assert reset.returncode == 0, reset.stdout + reset.stderr
    assert password not in reset.stdout
    with sqlite3.connect(path) as db:
        user = db.execute('SELECT id,is_active,password_hash FROM accounts').fetchone()
        assert user[:2] == ('patient-1', 1) and user[2].startswith('$argon2id$')
        assert db.execute('SELECT count(*) FROM reminders').fetchone()[0] == 1
    verify = subprocess.run([sys.executable, '-c',
        'import json,sys; from fastapi.testclient import TestClient; from app.main import app; '
        '\nwith TestClient(app) as c: '
        '\n r=c.post("/auth/login",json={"username":"patient","password":sys.stdin.readline().rstrip("\\n")});'
        '\n print(json.dumps({"status":r.status_code,"id":r.json().get("user_id")}))'],
        cwd=BACKEND, env=env, input=password + '\n', text=True, capture_output=True, timeout=30)
    assert verify.returncode == 0, verify.stderr
    assert json.loads(verify.stdout) == {'status': 200, 'id': 'patient-1'}


def test_production_rejects_http_even_with_spoofed_forwarded_header(client, monkeypatch):
    monkeypatch.setattr(config, 'PRODUCTION', True)
    response = client.post('/auth/register', headers={'X-Forwarded-Proto': 'https'},
        json={'username': 'newpatient', 'display_name': 'New Patient',
              'password': 'Production test only river 42!', 'role': 'patient'})
    assert response.status_code == 400 and response.json()['detail'] == 'HTTPS is required.'


def test_production_cookie_attributes(client, monkeypatch):
    body = {'username': 'caregiverone', 'display_name': 'Caregiver One',
            'password': 'Production test only river 42!', 'role': 'caregiver'}
    assert client.post('/auth/register', json=body).status_code == 201
    monkeypatch.setattr(config, 'PRODUCTION', True)
    monkeypatch.setattr(config, 'PUBLIC_ORIGIN', 'https://testserver')
    with TestClient(app, base_url='https://testserver') as secure_client:
        response = secure_client.post('/auth/web/login', json={'username': body['username'], 'password': body['password']},
            headers={'Origin': 'https://testserver'})
        assert response.status_code == 200
        for cookie in response.headers.get_list('set-cookie'):
            assert 'Secure' in cookie and 'SameSite=strict' in cookie
        assert 'HttpOnly' in next(c for c in response.headers.get_list('set-cookie') if c.startswith('mc_access='))
        assert secure_client.get('/auth/me').status_code == 200


def test_missing_and_placeholder_secret_fail_at_startup():
    for secret in ('', 'tiny', 'REPLACE_WITH_A_LONG_SECRET_PLACEHOLDER_123456'):
        env = {**os.environ, 'AUTH_SECRET_KEY': secret}
        result = subprocess.run([sys.executable, '-c', 'from app import config'],
            cwd=BACKEND, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and 'AUTH_SECRET_KEY must' in result.stderr


def test_production_requires_https_origin():
    env = {**os.environ, 'APP_ENV': 'production', 'PUBLIC_ORIGIN': 'http://memorycare.example'}
    result = subprocess.run([sys.executable, '-c', 'from app import config'],
        cwd=BACKEND, env=env, text=True, capture_output=True, timeout=15)
    assert result.returncode != 0 and 'Production requires' in result.stderr
