# Authentication upgrade: verification report

Date: 1 October 2026. Base repository commit: `947a4ac7ee4dba2988f1aad358d282c0a9e3505a`.

## Executed successfully

| Check | Result |
| --- | --- |
| Backend automated suite | 27 passed |
| Argon2id password storage | Verified hashed passwords and per-account credential verification |
| Weak passwords/validation | Rejected without echoing password input in validation responses |
| Login roles/extra fields | Wrong account role and mass-assignment fields rejected |
| Caregiver access | Unlinked caregiver denied; one-time link enforced; revocation denies later requests |
| Sessions | Refresh rotation, reuse detection, expiry, forged/wrong-audience JWTs and online logout tested |
| Password change | Old password fails and other devices' server sessions are revoked |
| Private media | Anonymous, other-patient and removed-caregiver requests denied |
| Offline synchronization | Real subprocess server-stop/write/restart/sync check passed; queue retained until acknowledged |
| Legacy data migration | Real old SQLite schema migrated; trusted password reset kept account ID and reminder |
| Production safeguards | Missing/placeholder secret and HTTP origin rejected; spoofed forwarded scheme rejected; Secure cookies verified |
| Browser CSRF/cookies | Same-origin checks, CSRF requirement, HttpOnly/SameSite and cookie rotation/logout tested |
| Dashboard form workflow | Virtual DOM plus real backend: registration, incorrect password, login, linking, renewal, password change and logout passed |
| Dashboard JavaScript | Syntax parsed successfully |
| Dart source | 13 Dart files parsed with no syntax errors |

The Python suite emitted one dependency deprecation warning about Starlette/httpx;
all tests passed. Test accounts, keys and databases were temporary and synthetic.
The backend was tested on Python 3.12 with FastAPI 0.142.2, SQLAlchemy 2.1.1,
PyJWT 2.15.1 and pwdlib 0.3.1.

## Not executed here

- Flutter dependency resolution, `flutter analyze`, Flutter widget tests and Android build:
  this environment does not contain the Flutter/Android SDK. Run the commands in
  AUTH_UPGRADE.md on the configured Windows PC; the new widget tests are included.
- Real-browser visual rendering: the executable was unavailable. The dashboard
  workflow was exercised through a virtual DOM, not a rendered Chromium window.
- PostgreSQL/Docker migration, HTTPS reverse-proxy deployment, iOS, production load
  tests, penetration testing, legal consent review or clinical validation.

## Required on-device checks

1. Upgrade without uninstalling the app; confirm old local reminders/memories persist.
2. Reset the original patient's password and sign in under the same account ID.
3. Register/sign in as caregiver; confirm no data appears before linking.
4. Link a patient, refresh and verify synchronized records/photos.
5. Create records offline, close/reopen, reconnect and check pending count reaches zero.
6. Remove access and confirm the caregiver cannot fetch patient records or media again.
7. Change a password and sign in again; test online/offline logout behavior.
8. Recheck English/Kannada/Hindi voice features after upgrading dependencies.

These tests support a demonstration upgrade, not a claim of production or clinical certification.
