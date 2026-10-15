"""Fail-closed security configuration; .env stays outside version control."""
import os
from pathlib import Path
from urllib.parse import urlsplit

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BACKEND_DIR / ".env", override=False)

SECRET_KEY = os.getenv("AUTH_SECRET_KEY", "")
if len(SECRET_KEY.encode()) < 32 or SECRET_KEY.startswith(('REPLACE_', 'replace-', 'change-')):
    raise RuntimeError(
        "AUTH_SECRET_KEY must be at least 32 bytes. Run python scripts/setup_auth.py "
        "from the project root to create backend/.env."
    )
APP_ENV = os.getenv("APP_ENV", "production")
if APP_ENV not in {"development", "production"}:
    raise RuntimeError("APP_ENV must be development or production")
PRODUCTION = APP_ENV == "production"
PUBLIC_ORIGIN = os.getenv("PUBLIC_ORIGIN", "").rstrip("/")
if PRODUCTION and not PUBLIC_ORIGIN.startswith("https://"):
    raise RuntimeError("Production requires an https:// PUBLIC_ORIGIN and a TLS proxy.")
if PUBLIC_ORIGIN:
    parsed = urlsplit(PUBLIC_ORIGIN)
    if not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
        raise RuntimeError('PUBLIC_ORIGIN must be an origin only, e.g. https://memorycare.example')
ACCESS_SECONDS = 15 * 60
SESSION_SECONDS = 7 * 24 * 60 * 60
JWT_ISSUER = "memorycare-api"
JWT_AUDIENCE = "memorycare-client"
ACCESS_COOKIE = "mc_access"
REFRESH_COOKIE = "mc_refresh"
CSRF_COOKIE = "mc_csrf"
