"""Authorization, credentials, refresh-token rotation and browser CSRF tests."""
import time
from uuid import uuid4

import jwt
import pytest
from sqlalchemy import select, update

from app import config
from app.models import Account, AuthSession, PatientInvite, RefreshToken, SessionLocal
from app.security import digest, password_hasher

PASSWORD = "Testing only sun garden 42!"
NEXT_PASSWORD = "Testing only sky river 84!"


def account(client, username="patientone", role="patient"):
    response = client.post('/auth/register', json={'username': username, 'display_name': username,
        'password': PASSWORD, 'role': role})
    assert response.status_code == 201, response.text
    login = client.post('/auth/login', json={'username': username, 'password': PASSWORD, 'role': role})
    assert login.status_code == 200, login.text
    return login.json()


def headers(session):
    return {'Authorization': 'Bearer ' + session['access_token']}


def link(client, patient, caregiver):
    code = client.post('/patients/invite', headers=headers(patient)).json()['code']
    response = client.post('/caregiver/link', headers=headers(caregiver), json={'code': code})
    assert response.status_code == 200
    return code


def test_argon2_hash_and_refresh_digest_only(client):
    result = account(client)
    with SessionLocal() as db:
        user = db.get(Account, result['user_id'])
        assert user.password_hash.startswith('$argon2id$')
        assert PASSWORD not in user.password_hash
        assert password_hasher.verify(PASSWORD, user.password_hash)
        assert db.get(RefreshToken, digest(result['refresh_token'])) is not None
        assert db.get(RefreshToken, result['refresh_token']) is None
    assert 'password_hash' not in client.get('/auth/me', headers=headers(result)).json()


@pytest.mark.parametrize('password', ['demo1234', '123456789012345', 'passwordpassword'])
def test_weak_password_rejected_without_echo(client, password):
    response = client.post('/auth/register', json={'username': 'patientone', 'display_name': 'Patient One',
        'password': password, 'role': 'patient'})
    assert response.status_code == 422
    assert password not in response.text
    assert '"input"' not in response.text


def test_role_tampering_and_mass_assignment_rejected(client):
    patient = account(client)
    response = client.post('/auth/login', json={'username': 'patientone', 'password': PASSWORD, 'role': 'caregiver'})
    assert response.status_code == 401
    assert client.get('/caregiver/patients', headers=headers(patient)).status_code == 403
    bad = client.post('/auth/register', json={'username': 'baduser', 'display_name': 'Bad User',
        'password': PASSWORD, 'role': 'patient', 'patient_id': 'someone-else', 'is_active': True})
    assert bad.status_code == 422


def test_username_normalization_and_duplicates(client):
    patient = account(client, 'PatientOne')
    assert patient['username'] == 'patientone'
    assert client.post('/auth/register', json={'username': 'PATIENTONE', 'display_name': 'Duplicate',
        'password': PASSWORD, 'role': 'caregiver'}).status_code == 409


def test_caregiver_consent_link_single_use_and_revocation(client):
    patient = account(client)
    caregiver = account(client, 'caregiverone', 'caregiver')
    stranger = account(client, 'caregivertwo', 'caregiver')
    assert client.get('/caregiver/summary', headers=headers(caregiver)).status_code == 404
    assert client.post('/sync', headers=headers(caregiver), json={'operations': []}).status_code == 403
    code = link(client, patient, caregiver)
    assert client.get('/caregiver/patients', headers=headers(caregiver)).json()['patients'][0]['user_id'] == patient['user_id']
    assert client.post('/caregiver/link', headers=headers(stranger), json={'code': code}).status_code == 400
    assert client.get('/caregiver/summary?patient_id=' + patient['user_id'], headers=headers(stranger)).status_code == 404
    assert client.get('/caregiver/summary', headers=headers(caregiver)).status_code == 200
    assert client.delete('/patients/caregivers/' + caregiver['user_id'], headers=headers(patient)).status_code == 200
    assert client.get('/caregiver/summary?patient_id=' + patient['user_id'], headers=headers(caregiver)).status_code == 404


def test_expired_and_replaced_codes_cannot_be_redeemed(client):
    patient = account(client)
    caregiver = account(client, 'caregiverone', 'caregiver')
    first = client.post('/patients/invite', headers=headers(patient)).json()['code']
    second = client.post('/patients/invite', headers=headers(patient)).json()['code']
    assert client.post('/caregiver/link', headers=headers(caregiver), json={'code': first}).status_code == 400
    with SessionLocal.begin() as db:
        db.execute(update(PatientInvite).values(expires_at=int(time.time()) - 1))
    assert client.post('/caregiver/link', headers=headers(caregiver), json={'code': second}).status_code == 400


def test_refresh_rotation_reuse_revokes_whole_session(client):
    first = account(client)
    response = client.post('/auth/refresh', json={'refresh_token': first['refresh_token']})
    assert response.status_code == 200
    second = response.json()
    assert first['refresh_token'] != second['refresh_token']
    assert first['refresh_expires_at'] == second['refresh_expires_at']  # Absolute lifetime.
    assert client.get('/auth/me', headers=headers(second)).status_code == 200
    assert client.post('/auth/refresh', json={'refresh_token': first['refresh_token']}).status_code == 401
    assert client.get('/auth/me', headers=headers(second)).status_code == 401
    assert client.post('/auth/refresh', json={'refresh_token': second['refresh_token']}).status_code == 401


def test_logout_revokes_access_and_refresh(client):
    session = account(client)
    assert client.post('/auth/logout', headers=headers(session)).status_code == 200
    assert client.get('/auth/me', headers=headers(session)).status_code == 401
    assert client.post('/auth/refresh', json={'refresh_token': session['refresh_token']}).status_code == 401


def test_password_change_revokes_other_devices(client):
    first = account(client)
    second = client.post('/auth/login', json={'username': 'patientone', 'password': PASSWORD}).json()
    wrong = client.post('/auth/change-password', headers=headers(first), json={'current_password': 'wrong', 'new_password': NEXT_PASSWORD})
    assert wrong.status_code == 400
    changed = client.post('/auth/change-password', headers=headers(first), json={'current_password': PASSWORD, 'new_password': NEXT_PASSWORD})
    assert changed.status_code == 200
    assert client.get('/auth/me', headers=headers(first)).status_code == 401
    assert client.get('/auth/me', headers=headers(second)).status_code == 401
    assert client.post('/auth/login', json={'username': 'patientone', 'password': PASSWORD}).status_code == 401
    assert client.post('/auth/login', json={'username': 'patientone', 'password': NEXT_PASSWORD}).status_code == 200


def test_login_rate_limit(client):
    account(client)
    for _ in range(9):
        assert client.post('/auth/login', json={'username': 'patientone', 'password': 'incorrect'}).status_code == 401
    response = client.post('/auth/login', json={'username': 'patientone', 'password': PASSWORD})
    assert response.status_code == 429
    assert int(response.headers['Retry-After']) > 0


def test_forged_expired_and_wrong_audience_tokens(client):
    session = account(client)
    claims = jwt.decode(session['access_token'], options={'verify_signature': False})
    for changes, key in [({}, 'attacker-key-' * 4), ({'exp': int(time.time()) - 60}, config.SECRET_KEY),
                         ({'aud': 'other-app'}, config.SECRET_KEY), ({'type': 'refresh'}, config.SECRET_KEY)]:
        token = jwt.encode({**claims, **changes}, key, algorithm='HS256')
        assert client.get('/auth/me', headers={'Authorization': 'Bearer ' + token}).status_code == 401
    with SessionLocal.begin() as db:
        db.execute(update(AuthSession).values(expires_at=int(time.time()) - 1))
    assert client.get('/auth/me', headers=headers(session)).status_code == 401


def test_web_cookie_login_csrf_and_rotation(client):
    caregiver = account(client, 'caregiverone', 'caregiver')
    body = {'username': 'caregiverone', 'password': PASSWORD}
    assert client.post('/auth/web/login', json=body).status_code == 403
    assert client.post('/auth/web/login', headers={'Origin': 'https://attacker.example'}, json=body).status_code == 403
    response = client.post('/auth/web/login', headers={'Origin': 'http://testserver'}, json=body)
    assert response.status_code == 200
    assert 'access_token' not in response.json() and 'refresh_token' not in response.json()
    cookies = response.headers.get_list('set-cookie')
    assert any('mc_access=' in c and 'HttpOnly' in c and 'SameSite=strict' in c for c in cookies)
    assert any('mc_refresh=' in c and 'HttpOnly' in c and 'Path=/auth/web' in c for c in cookies)
    assert client.get('/auth/me').json()['role'] == 'caregiver'
    assert client.post('/auth/logout', headers={'Origin': 'http://testserver'}).status_code == 403
    csrf = client.cookies.get('mc_csrf')
    assert client.post('/auth/web/refresh', headers={'Origin': 'https://attacker.example', 'X-CSRF-Token': csrf}).status_code == 403
    assert client.post('/auth/web/refresh', headers={'Origin': 'http://testserver', 'X-CSRF-Token': csrf}).status_code == 200
    next_csrf = client.cookies.get('mc_csrf')
    assert next_csrf != csrf
    assert client.post('/auth/logout', headers={'Origin': 'http://testserver', 'X-CSRF-Token': next_csrf}).status_code == 200
    assert client.get('/auth/me').status_code == 401
    # Logging out one browser session must not revoke the separate mobile session.
    assert client.get('/auth/me', headers=headers(caregiver)).status_code == 200


def test_private_media_checks_account_and_link(client):
    patient = account(client)
    other = account(client, 'patienttwo')
    caregiver = account(client, 'caregiverone', 'caregiver')
    memory_id = str(uuid4())
    op = {'id': str(uuid4()), 'kind': 'memory', 'payload': {'id': memory_id,
        'person_name': 'Asha', 'relationship': 'Daughter', 'note': 'Test only'}}
    assert client.post('/sync', headers=headers(patient), json={'operations': [op]}).status_code == 200
    response = client.post(f'/memories/{memory_id}/media/photo', headers=headers(patient),
        files={'file': ('test.jpg', b'test-only-image-bytes', 'image/jpeg')})
    assert response.status_code == 200
    link(client, patient, caregiver)
    row = client.get('/caregiver/summary', headers=headers(caregiver)).json()['memories'][0]
    assert client.get(row['photo_url']).status_code == 401
    assert client.get(row['photo_url'], headers=headers(other)).status_code == 404
    assert client.get(row['photo_url'], headers=headers(patient)).status_code == 200
    assert client.get(row['photo_url'], headers=headers(caregiver)).status_code == 200
    client.delete('/patients/caregivers/' + caregiver['user_id'], headers=headers(patient))
    assert client.get(row['photo_url'], headers=headers(caregiver)).status_code == 404


def test_cross_patient_object_update_and_delete_denied(client):
    first = account(client)
    other = account(client, 'patienttwo')
    reminder_id = str(uuid4())
    op = {'id': str(uuid4()), 'kind': 'reminder', 'payload': {'id': reminder_id, 'title': 'Private', 'due_at': '2026-10-01T12:00:00'}}
    assert client.post('/sync', headers=headers(first), json={'operations': [op]}).status_code == 200
    op['id'] = str(uuid4())
    assert client.post('/sync', headers=headers(other), json={'operations': [op]}).status_code in {403, 409}
    op = {'id': str(uuid4()), 'kind': 'delete_reminder', 'payload': {'id': reminder_id}}
    assert client.post('/sync', headers=headers(other), json={'operations': [op]}).status_code in {403, 409}


def test_dashboard_has_nonce_csp_and_no_default_credentials(client):
    response = client.get('/dashboard')
    assert response.status_code == 200
    assert '<script nonce="' in response.text
    assert "'unsafe-inline'" not in response.headers['Content-Security-Policy']
    assert 'demo1234' not in response.text
    assert response.headers['Cache-Control'] == 'no-store'


def test_legacy_account_is_disabled_without_deleting_its_id(client):
    from fastapi.testclient import TestClient
    from app.main import app
    with SessionLocal.begin() as db:
        db.add(Account(id='patient-1', username='patient', password_hash='old-pbkdf2-demo-hash',
            role='patient', patient_id='patient-1', display_name='Old Patient', is_active=True))
    with TestClient(app) as restarted:
        assert restarted.post('/auth/login', json={'username': 'patient', 'password': 'demo1234'}).status_code == 401
    with SessionLocal() as db:
        old = db.get(Account, 'patient-1')
        assert old is not None and not old.is_active
