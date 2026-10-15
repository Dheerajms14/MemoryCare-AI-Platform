# MemoryCare 2.1

AI-Based Cognitive Gaming and Memory Assistance Platform for Elderly Dementia Patients.

An academic Flutter/FastAPI assistance prototype. It does not diagnose dementia,
perform clinical assessment, recommend treatment or make therapeutic claims.

## Start here

Read [AUTH_UPGRADE.md](AUTH_UPGRADE.md) for the exact Windows/VS Code commands,
data-preserving migration and patient/caregiver linking workflow.

The former shared demo passwords no longer work. Individual accounts use Argon2id,
revocable sessions, protected mobile token storage and server-enforced access checks.
Existing demo accounts must be reset with the trusted local operator tool, preserving
their IDs and records. New caregivers see no patient data until explicitly linked.

## Modules

| Module | Implementation |
| --- | --- |
| Patient app | Home, reminders, four cognitive-game types, Memory Vault, progress and settings |
| Caregiver app | Separate server-authorized summary; does not expose the patient SQLite cache |
| Registration/login | Separate patient/caregiver forms; full name, username, confirmed passphrase |
| Access control | Stored account role plus patient-controlled one-time linking |
| Language | English, Kannada and Hindi; saved preference |
| Voice | Text-to-speech, supported speech-service navigation, local familiar-voice recordings |
| Memory Vault | Name, relationship, note, photo and voice |
| Reminders | Medicine, appointment, activity and general reminders |
| Adaptive recommendation | Transparent rule-based demonstration; not a trained clinical/ML model |
| Offline operation | Local SQLite records and atomic outbox; only acknowledged operations are removed |
| Server | FastAPI, SQLite for the local demo or optional PostgreSQL |
| Media | Upload after parent record; authenticated download, no public static media directory |
| Dashboard | Caregiver registration/login, linking, patient selection, summary and password change |

## Local demonstration

Generate your own server secret with `python scripts/setup_auth.py` after installing
`backend/requirements.txt`. Start from `backend/` using
`python -m uvicorn app.main:app --host 127.0.0.1 --port 8000`.
For the physical Android phone use an authorized USB `adb reverse` tunnel.
Run Flutter in debug mode with `--dart-define=MEMORYCARE_ALLOW_HTTP=true`.
See the guide for full executable paths and old-account reset commands.

Do not uninstall the old phone app or clear its data during an upgrade. Keep the
server working directory and database path unchanged. Back up before applying changes.

## Verification

Backend: `python -m pytest backend/tests -q` after installing requirements-test.txt.
End-to-end offline check: `python scripts/smoke_test.py`.
Flutter: `flutter pub get`, `flutter analyze`, `flutter test`, then run on the phone.
Tests use temporary databases, not real patient data.
See [TEST_REPORT.md](TEST_REPORT.md) for what was actually verified.

## Research/design basis

- Harris et al., *The REDCap Mobile Application*, JAMIA Open (2021):
  https://doi.org/10.1093/jamiaopen/ooab078 — offline collection and later synchronization.
- Mishra et al., *Care4AD*, Gerontology (2023):
  https://doi.org/10.1159/000526219 — caregiver coordination and reminder support.
- Ortega Morán et al., *A Serious Game for Cognitive Stimulation of Older People With
  Mild Cognitive Impairment*, JMIR Aging (2024):
  https://doi.org/10.2196/41437 — familiar cognitive activities.

This is original academic demonstration code, not the original source code of these systems.
Authentication guidance comes from FastAPI and OWASP documentation linked in the guide.

## Limitations

Local HTTP is unencrypted and for synthetic demo data only. Production must use HTTPS;
release builds reject HTTP. Secure storage protects tokens, not the reminder/memory SQLite
database. This update is not a certified clinical system and does not implement MFA,
verified caregiver identity, email OTP, public password recovery, full at-rest database
encryption, comprehensive audit logging or deployment-specific security review.
A disconnected device cannot immediately learn about remote revocation.
Background reminder alarms are not implemented. Speech-service availability varies by phone.
