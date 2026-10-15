"""Trusted local operator recovery; there is intentionally no anonymous reset API.

Run from backend: python -m app.manage_accounts --username patient
Use this to secure the OLD patient/caregiver accounts while preserving their IDs.
"""
import argparse
from getpass import getpass

from sqlalchemy import select, update

from .main import _migrate_existing_database
from .models import Account, AuthSession, Base, SessionLocal, engine
from .security import password_hasher, validate_password


def main():
    parser = argparse.ArgumentParser(description="Reset a local account with server-operator authority.")
    parser.add_argument("--username", required=True)
    args = parser.parse_args()
    Base.metadata.create_all(engine)
    _migrate_existing_database()
    with SessionLocal.begin() as db:
        user = db.scalar(select(Account).where(Account.username == args.username.lower()))
        if not user:
            raise SystemExit("Account not found. Create new accounts in the app or dashboard.")
        print(f"Resetting {user.username} ({user.role}); existing ID and data will be kept.")
        first = getpass("New passphrase (15-128 characters): ")
        second = getpass("Confirm new passphrase: ")
        if first != second:
            raise SystemExit("Passphrases differ; nothing changed.")
        try:
            validate_password(first, user.username)
        except ValueError as error:
            raise SystemExit(str(error)) from None
        user.password_hash = password_hasher.hash(first)
        user.is_active = True
        user.display_name = user.display_name or user.username
        db.execute(update(AuthSession).where(AuthSession.account_id == user.id).values(revoked=True))
    print("Password secured. All old sessions are invalid. Sign in with the new passphrase.")
    print("Caregiver access still requires a new patient linking code.")


if __name__ == "__main__":
    main()
