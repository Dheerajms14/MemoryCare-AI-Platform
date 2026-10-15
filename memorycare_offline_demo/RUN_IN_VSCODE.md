# Run MemoryCare 2.1 in VS Code

Follow [AUTH_UPGRADE.md](AUTH_UPGRADE.md) in order:

1. Stop the old server/app and back up the database.
2. Apply the patch to the existing Git repository.
3. Install backend packages using the virtual environment in the outer folder.
4. Generate a private server secret.
5. Reset old demo account passwords locally, preserving their IDs.
6. Start the backend in one terminal.
7. Authorize the phone, set up USB reverse forwarding and run Flutter in another terminal.
8. Sign in as the patient; link a separate caregiver using a short-lived code.
9. Test offline writes, reconnection, password changes and access revocation.

Old `patient/demo1234` and `caregiver/demo1234` credentials are not accepted.
Do not uninstall the phone app, delete its SQLite database, or delete a Docker volume.
Do not rerun `flutter create` or enable cleartext traffic in the release manifest.
The complete guide contains the exact commands for your existing Windows paths.
