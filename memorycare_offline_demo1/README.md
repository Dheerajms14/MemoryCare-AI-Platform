# MemoryCare: offline demonstration code

This is runnable demonstration code for Dheeraj's application and backend role in the
**AI-Based Cognitive Gaming and Memory Assistance Platform for Elderly Dementia Patients**.
The uploaded role sheet specifies Flutter, FastAPI, PostgreSQL, login, role-based access,
offline storage, and synchronization. This repository implements those pieces.

## What happens while offline

1. The patient signs in once while connected to the local backend.
2. Every reminder, memory note, and game result is written to SQLite **together with**
   an unsent outbox operation in one database transaction.
3. The patient can close and reopen the app and still see saved items.
4. When the network returns, the app sends queued operations to POST /sync.
5. The backend validates the patient role and writes a complete batch to PostgreSQL.
   It records each operation ID so a retry cannot add a second copy.
6. The app removes only operations that the server acknowledged. The caregiver dashboard
   shows the data after synchronization.

An offline-mode switch prevents uploads during an in-person demonstration. A real network
failure has the same queue-retention behavior; the app retries approximately every 20 seconds.

## Option A: complete PC-only demonstration (no Flutter needed)

Install Python 3.11+ and Docker Desktop. From this repository's root:

~~~text
docker compose up --build -d
python pc_demo/offline_demo.py init
docker compose stop api
python pc_demo/offline_demo.py offline
python pc_demo/offline_demo.py show
python pc_demo/offline_demo.py sync
docker compose start api
python pc_demo/offline_demo.py sync
python pc_demo/offline_demo.py show
~~~

The first sync, while the API is stopped, prints a connection error and retains all
three queued changes. The second sync confirms three changes and reports zero pending.
Open http://127.0.0.1:8000/dashboard and sign in as **caregiver / demo1234**.
Refresh to see the medicine reminder, memory note, and game result.

On Windows PowerShell, replace "python" with "py" if that is your Python command.
The CLI's SQLite file is pc_demo/data/device.db. It is a PC simulation of the phone's
SQLite queue, using the **same sync API contract** as the Flutter application.
The PC demo runs only on the local machine; no device or internet is required after
Docker images and Python dependencies have been obtained.

## Option B: Flutter Android demonstration

Keep Docker Compose running. Install Flutter, the Android SDK, and an Android emulator
or USB-connected phone. In a terminal at this repository's root, run:

~~~text
cd mobile
flutter create . --platforms=android
flutter pub get
cd ..
python scripts/allow_local_http.py
cd mobile
flutter run
~~~

The Flutter command generates the standard Android platform files on your PC while
keeping the provided Flutter source. The included helper adds INTERNET permission and
allows local HTTP **for this demonstration only**.

For the Android emulator, the app's default backend URL is
http://10.0.2.2:8000 (the emulator's route to the PC). For a physical Android phone,
enter http://YOUR_PC_LAN_IP:8000 on the login screen; keep both devices on the same
network and allow local port 8000 through your PC firewall. The server is exposed by
Docker at port 8000.

Sign in as **patient / demo1234** while online. Turn on the app's **Offline demo mode**.
Add a medicine reminder, save a person's memory note, and answer any of the four
example games. The pending counter increases. Fully close and reopen the app; the
locally saved items remain. Turn offline mode off, tap **Sync now**, then refresh the
caregiver dashboard at http://127.0.0.1:8000/dashboard. You can also disconnect the
actual network after sign-in to show that saving does not depend on the server.

## Without Docker (backend-only fallback)

For a quick PC-only run with a SQLite server database instead of PostgreSQL:

~~~text
cd backend
python -m venv .venv
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
~~~

Activate the virtual environment or use its Python interpreter when running the final
two commands. With no DATABASE_URL variable, the API stores its test data in
backend/memorycare_server.db. Stop/restart the API process to simulate disconnection.
Use Docker Compose for the role's PostgreSQL demonstration.

## Source code map

| File | Purpose |
| --- | --- |
| mobile/lib/local_store.dart | On-device SQLite records and atomic outbox writes |
| mobile/lib/api.dart | Online login, batched sync, acknowledgment checking |
| mobile/lib/main.dart | Elderly-friendly mobile screens and four short game examples |
| backend/app/main.py | FastAPI login, roles, PostgreSQL models, idempotent sync |
| backend/app/dashboard.html | Caregiver's same-origin browser view |
| pc_demo/offline_demo.py | Local PC demonstration using only Python standard library |
| backend/tests/test_sync.py | Replay, authorization, atomic rollback checks |
| scripts/smoke_test.py | Live API up/down/up offline sync check |

API documentation: http://127.0.0.1:8000/docs. Health check:
http://127.0.0.1:8000/health.

## Research basis

- Harris et al., *The REDCap Mobile Application: a data collection platform for
  research in regions or situations with internet scarcity*, JAMIA Open (2021),
  https://doi.org/10.1093/jamiaopen/ooab078.
  We adapted the **idea** of a durable local activity log followed by later synchronization.
- Mishra et al., *Care4AD: A Technology-Driven Platform for Care Coordination and
  Management*, Gerontology (2023), https://doi.org/10.1159/000526219.
  It motivates caregiver-facing activity and reminder support.
- Mabotha et al., *Exploring dynamic RESTful API implementation in IoT environments
  using Docker*, Scientific Reports (2025),
  https://doi.org/10.1038/s41598-025-16460-0.
  It informs the containerized API/database demonstration.

This is original demonstration code built for the project; it is not source code taken
from the papers.

## One-minute explanation for a presentation

“First, I sign in online. When I switch to offline mode, the reminder, memory note,
and game result go into on-device SQLite. The pending-upload counter increases and
the caregiver cannot see the new information yet. When I reconnect, the FastAPI server
stores each change in PostgreSQL, acknowledges it, and the pending counter returns to
zero. A repeated upload is safe because each operation has a unique ID.”

## Scope

This academic demo includes four **example** game questions; it does not implement
the team's trained AI difficulty model. The Memory Vault supports text notes here,
without photo or audio upload. Reminders appear in the app while offline; background
alarm notifications are not implemented. The dashboard is a simple view for one
linked patient and caregiver. Demo passwords, local HTTP, and a stored demo token are
for local demonstration; a deployed health application needs secure token storage,
TLS, stronger account management, consent and privacy controls. It does not diagnose
or treat dementia.

Run the targeted backend tests after installing backend/requirements-test.txt:

~~~text
cd backend
python -m pip install -r requirements-test.txt
python -m pytest -q
~~~

Then, from the repository root, run python scripts/smoke_test.py for an automated
end-to-end version of the PC demonstration. It uses a temporary SQLite backend and
cleans up its test data.
