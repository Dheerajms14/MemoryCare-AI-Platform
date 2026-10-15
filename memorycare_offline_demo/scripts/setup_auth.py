"""One-time local setup. Creates a random secret; never prints or overwrites it."""
from pathlib import Path
import secrets


def main():
    target = Path(__file__).resolve().parents[1] / "backend" / ".env"
    if target.exists():
        print("backend/.env already exists; it was not overwritten.")
        return
    contents = (
        "# Local demo only. Production needs HTTPS; see AUTH_UPGRADE.md.\n"
        "APP_ENV=development\n"
        f"AUTH_SECRET_KEY={secrets.token_urlsafe(48)}\n"
        "# PUBLIC_ORIGIN=https://your-production-domain.example\n"
    )
    try:
        with target.open("x", encoding="utf-8") as output:
            output.write(contents)
        target.chmod(0o600)
    except FileExistsError:
        print("backend/.env was created elsewhere; it was not overwritten.")
        return
    print("Created backend/.env with a random key. Keep it private and do not commit it.")


if __name__ == "__main__":
    main()
