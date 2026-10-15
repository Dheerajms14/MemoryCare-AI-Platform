# MemoryCare 2.1: secure patient and caregiver accounts

Based on your GitHub commit `947a4ac7ee4dba2988f1aad358d282c0a9e3505a`.
This bundle changes source code only; it does not push anything to GitHub.
Commands below are for PowerShell. Copy commands, not `PS ...>` or `>>` prompts.

## What is included

| Feature | Implementation |
| --- | --- |
| Separate accounts | Patient/caregiver registration, login, full name, username and confirmed passphrase |
| Passwords | Argon2id hashing; 15–128 characters; no plaintext password storage |
| Authorization | Server checks account role and patient–caregiver link on protected requests |
| Patient linking | Random single-use code; 10-minute expiry; patient can remove access |
| Sessions | Access JWT up to 15 minutes; rotating refresh tokens; 7-day absolute lifetime |
| Mobile storage | `flutter_secure_storage` for tokens, not SQLite |
| Browser storage | HttpOnly session cookies, SameSite=Strict, CSRF protection, nonce-based CSP |
| Abuse controls | Database-backed per-IP/per-username limits |
| Password change | Revokes all server sessions; online logout revokes the current session |
| Private media | Photos/audio accessible only to owner/linked caregiver |
| Offline data | Existing IDs, SQLite records, outboxes and media preserved |

`caregiver` is the code/API name for the caretaker role. The role selector does not
grant access by itself: the server checks the stored account role.

## 1. Stop and back up

Stop the backend with Ctrl+C and Flutter with `q`. Do not uninstall/clear the phone
app: that deletes its unsynchronized data. From the current project:

```powershell
cd "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\memorycare_offline_demo"
git status
git switch -c feature/secure-auth
if (Test-Path ".\backend\memorycare_server.db") { if (Test-Path ".\backend\memorycare_server.backup.db") { throw "Backup already exists. Choose a new backup filename before continuing." }; Copy-Item ".\backend\memorycare_server.db" ".\backend\memorycare_server.backup.db" -ErrorAction Stop }
```

Review and commit any existing source edits before applying the patch. If a backup
already exists, choose a different filename; do not overwrite it. PostgreSQL users
should back up with `pg_dump` instead. Never delete a database volume.

## 2. Apply the update

Extract `MemoryCare_Auth_Update.zip` to Downloads. It contains the patch, this guide,
the test report, and a complete `memorycare_offline_demo/` source folder without
databases, SDKs, environments, secrets, build outputs or Git history.

In your EXISTING project root:

```powershell
git apply --check "C:\Users\Dheeraj\Downloads\MemoryCare_Auth_Update\memorycare_auth.patch"
git apply "C:\Users\Dheeraj\Downloads\MemoryCare_Auth_Update\memorycare_auth.patch"
```

Use the actual extraction path. Run the second command only if the check succeeds.
If it fails, stop and share the error; do not force it. The patch does not replace
your `.env`, database, offline queue, media or signing key. Keep using the existing
project folder, rather than creating a new empty database in the extracted copy.

## 3. Install packages and create the server secret

Your Python environment is in the OUTER folder, not inside `backend`. These commands
use its executable directly; activation/execution-policy changes are unnecessary.

```powershell
cd "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\memorycare_offline_demo"
$projectPython = "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\.venv\Scripts\python.exe"
if (!(Test-Path $projectPython)) { py -m venv "..\.venv" }
& $projectPython -m pip install -r ".\backend\requirements.txt"
& $projectPython ".\scripts\setup_auth.py"
```

The helper creates `backend/.env`, a random secret and `APP_ENV=development` for
local testing. It never overwrites an existing `.env`. If one already exists,
configure its `AUTH_SECRET_KEY` with at least 32 random bytes. No insecure default
secret is accepted. Never paste the key into chat, Flutter code or GitHub.

## 4. Reset the old accounts WITHOUT losing data

The old published `demo1234` password and old tokens no longer work. If your database
has the original `patient` and `caregiver` accounts, reset them locally before
starting the server:

```powershell
cd ".\backend"
& $projectPython -m app.manage_accounts --username patient
& $projectPython -m app.manage_accounts --username caregiver
```

Enter different unique passphrases of 15–128 characters when prompted. These
commands preserve `patient-1`, `caregiver-1` and their records. A fresh database has
NO default accounts: register through the app/dashboard instead.

If an old account is not found, check the database path and `DATABASE_URL`; do not
create a new patient to upload another patient's old offline queue. Old caregiver
access is not automatically trusted; use a new linking code after signing in.

## 5. Start backend: terminal 1

```powershell
cd "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\memorycare_offline_demo\backend"
& "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\.venv\Scripts\python.exe" -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Keep it running. Dashboard: `http://127.0.0.1:8000/dashboard`.
If port 8000 is occupied, stop the previous server; do not launch another copy.

## 6. Run on the Motorola: terminal 2

USB debugging must be enabled, the phone unlocked, and the computer authorized.
The USB reverse tunnel avoids Wi-Fi IP changes and opening firewall ports.

```powershell
cd "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\memorycare_offline_demo\mobile"
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" -s ZD222CCLFX reverse tcp:8000 tcp:8000
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" pub get
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" analyze
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" test
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" run -d ZD222CCLFX --dart-define=MEMORYCARE_ALLOW_HTTP=true
```

The device must show `device`, not `unauthorized`. Enter `http://127.0.0.1:8000`
in the app's server field for this USB setup. Replace any saved old Wi-Fi address.
Re-run `adb reverse` after reconnecting/rebooting. `pub get` updates the lock file;
commit it after testing. Do not run `flutter clean` routinely.

For Wi-Fi testing instead, bind the backend to `0.0.0.0`, use the PC's current Wi-Fi
IPv4 address and allow access only on a trusted private network. Local HTTP is
unencrypted: use synthetic test data only. Release builds reject HTTP even if the
demo flag is passed. The old HTTP helper no longer modifies the release manifest.

## 7. Test the roles

1. Select **Patient** in the app and sign in with the reset original account.
2. Add reminders/memories/game results and sync.
3. Open **Settings → Caregiver access → Create linking code**.
4. Sign in with a separate **Caregiver** account in the dashboard or app.
   New caregivers see NO patient data until linked.
5. Enter the patient's 24-character code within 10 minutes and select the patient.
6. Remove caregiver access from the patient app: future summary/media requests
   must be denied. Previously downloaded information cannot be remotely erased.
7. Change a passphrase: all server sessions are revoked. Online sign-out revokes
   the current session only.

The phone's local cache stays bound to one patient. Signing out does not delete
it or allow another patient to upload it. The caregiver mobile view uses authorized
server data, never the local patient cache. It requires connectivity.

## 8. Offline check and PC demo

After signing in online, stop the server or enable Offline demo mode. Create records,
close/reopen the app, reconnect and sync: only acknowledged queue rows are removed.
Turning Wi-Fi off is NOT an offline test while the USB reverse tunnel is active.
Saved patient sessions permit local use for up to seven days; after expiry, sign in
online again. Revocations/password changes cannot be learned while disconnected.
Offline sign-out clears this phone's tokens but cannot revoke the server session.
Enable the phone's screen lock.

PC demo now privately asks for the registered patient's passphrase at `init` and
`sync`; it stores the account binding, not credentials:

```powershell
cd "C:\Users\Dheeraj\Downloads\MemoryCare_Offline_Demo_Dheeraj\memorycare_offline_demo"
& "..\.venv\Scripts\python.exe" ".\pc_demo\offline_demo.py" init --username patient
& "..\.venv\Scripts\python.exe" ".\pc_demo\offline_demo.py" offline
& "..\.venv\Scripts\python.exe" ".\pc_demo\offline_demo.py" sync --username patient
& "..\.venv\Scripts\python.exe" ".\pc_demo\offline_demo.py" show
```

## 9. Backend tests and Git

Tests use temporary databases, not your real data:

```powershell
& "..\.venv\Scripts\python.exe" -m pip install -r ".\backend\requirements-test.txt"
& "..\.venv\Scripts\python.exe" -m pytest ".\backend\tests" -q
& "..\.venv\Scripts\python.exe" ".\scripts\smoke_test.py"
git status
git diff --stat
git add .
git diff --cached --stat
git commit -m "Add individual patient and caregiver authentication"
git push -u origin feature/secure-auth
```

Review staged files before committing. Never commit `.env`, databases, media, virtual
environments or signing keys. The push above is optional and for you to run when ready.

## Main code files

| File | Purpose |
| --- | --- |
| `backend/app/config.py` | Fail-closed configuration |
| `backend/app/models.py` | Accounts, sessions, refresh hashes and links |
| `backend/app/security.py` | Hashing, JWT verification, roles, CSRF, throttling |
| `backend/app/auth.py` | Register/login/refresh/logout/change password/link/revoke |
| `backend/app/manage_accounts.py` | Trusted local reset preserving account IDs |
| `mobile/lib/auth_service.dart` | Secure storage and automatic access-token renewal |
| `mobile/lib/auth_screen.dart` | Patient/caregiver registration and login forms |
| `mobile/lib/caregiver_screen.dart` | Authorized mobile caregiver view |
| `mobile/lib/account_actions.dart` | Password change |
| `backend/app/dashboard.html` | Cookie-authenticated caregiver portal |

Mobile uses `/auth/register`, `/auth/login`, `/auth/refresh` and bearer authorization.
Browser uses `/auth/web/login`, `/auth/web/refresh`, HttpOnly cookies and CSRF headers.
Never put tokens in URLs or browser local/session storage.

## Before real deployment

This is a stronger academic prototype, not a security-certified clinical system.
Set `APP_ENV=production` and an exact HTTPS `PUBLIC_ORIGIN`; configure TLS and trust
forwarded headers only from your specific reverse proxy. Use unique server secrets,
least-privilege PostgreSQL access, protected backups and server/device encryption.

Tokens are protected, but reminder/memory SQLite records are NOT encrypted by this
update. It does not include MFA/passkeys, verified caregiver identity, email OTP,
comprehensive breached-password checking or public forgotten-password recovery.
The operator reset tool requires trusted PC/database access; it is not a public API.
Add privacy-safe audit logs, request limits, content-level media validation, session
cleanup, monitoring and independent security/privacy review before using real health
data. Technical linking does not replace lawful consent/ethics review.

Docker is optional: back up an existing PostgreSQL volume and keep its configured
password. For a NEW isolated database, set a random URL-safe `POSTGRES_PASSWORD` in
root `.env`, create `backend/.env`, then run `docker compose up --build`. Never use
`docker compose down -v` on data you need.

Guidance: [FastAPI JWT](https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/),
[OWASP password storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html),
[OWASP sessions](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html),
[Flutter secure storage](https://pub.dev/packages/flutter_secure_storage).
