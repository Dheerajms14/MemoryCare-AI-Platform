"""Password hashing, JWT verification, CSRF and database-backed throttling."""
import hashlib
import hmac
import time
from urllib.parse import urlsplit
from uuid import uuid4

from fastapi import Depends, HTTPException, Request
import jwt
from jwt.exceptions import InvalidTokenError
from pwdlib import PasswordHash
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import config
from .models import Account, AuthRateLimit, AuthSession, CaregiverLink, get_db

password_hasher = PasswordHash.recommended()
DUMMY_HASH = password_hasher.hash("unusable timing equalization password")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def validate_password(value: str, username: str = "") -> str:
    if not 15 <= len(value) <= 128:
        raise ValueError("Use a passphrase of 15 to 128 characters.")
    if value.casefold() in {
        "passwordpassword", "password123456789", "123456789012345", "qwertyuiopasdfgh",
    } or (username and value.casefold() == username.casefold()):
        raise ValueError("Choose a less predictable passphrase.")
    return value  # Never trim, truncate, or silently normalize a password.


def check_password(password: str, stored: str) -> bool:
    try:
        return password_hasher.verify(password, stored)
    except Exception:
        return False


def require_https(request: Request) -> None:
    if config.PRODUCTION and request.url.scheme != "https":
        raise HTTPException(400, "HTTPS is required.")


def check_web_origin(request: Request) -> None:
    require_https(request)
    expected = config.PUBLIC_ORIGIN or str(request.base_url).rstrip("/")
    supplied = request.headers.get("origin")
    if supplied is None:
        referrer = request.headers.get("referer", "")
        parsed = urlsplit(referrer)
        supplied = f"{parsed.scheme}://{parsed.netloc}" if parsed.netloc else None
    if supplied != expected:
        raise HTTPException(403, "Same-origin browser request required.")


def check_csrf(request: Request, session: AuthSession) -> None:
    check_web_origin(request)
    cookie = request.cookies.get(config.CSRF_COOKIE, "")
    header = request.headers.get("X-CSRF-Token", "")
    if not cookie or not header or not hmac.compare_digest(cookie, header):
        raise HTTPException(403, "CSRF token required.")
    if not hmac.compare_digest(digest(header), session.csrf_hash):
        raise HTTPException(403, "Invalid CSRF token.")


def throttle(db: Session, request: Request, scope: str, limit: int, seconds: int, subject: str = "", *, per_peer: bool = True) -> None:
    """Count all attempts, not just failures. Atomic conditional UPDATE prevents races.

    Only the network peer is trusted; arbitrary X-Forwarded-For is not read here.
    A deployment should also rate-limit at its reverse proxy.
    """
    peer = request.client.host if request.client else "unknown"
    if not per_peer:
        peer = '*'  # Account-wide limit also covers attempts from different IPs.
    key = digest(f"{scope}:{peer}:{subject}")
    window = int(time.time()) // seconds
    if db.get(AuthRateLimit, key) is None:
        db.add(AuthRateLimit(key=key, window=window, count=0))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
    db.execute(update(AuthRateLimit).where(
        AuthRateLimit.key == key, AuthRateLimit.window != window,
    ).values(window=window, count=0))
    changed = db.execute(update(AuthRateLimit).where(
        AuthRateLimit.key == key, AuthRateLimit.window == window, AuthRateLimit.count < limit,
    ).values(count=AuthRateLimit.count + 1)).rowcount
    db.commit()
    if not changed:
        retry = seconds - int(time.time()) % seconds
        raise HTTPException(429, "Too many attempts. Please wait and try again.", headers={"Retry-After": str(retry)})


def access_token(user: Account, session: AuthSession) -> str:
    now = int(time.time())
    return jwt.encode({
        "sub": user.id, "sid": session.id, "jti": str(uuid4()), "type": "access",
        "iat": now, "exp": min(now + config.ACCESS_SECONDS, session.expires_at),
        "iss": config.JWT_ISSUER, "aud": config.JWT_AUDIENCE,
    }, config.SECRET_KEY, algorithm="HS256")


def current_user(request: Request, db: Session = Depends(get_db)) -> Account:
    require_https(request)
    authorization = request.headers.get("authorization")
    from_cookie = authorization is None
    token = request.cookies.get(config.ACCESS_COOKIE) if from_cookie else None
    if authorization is not None and authorization.startswith("Bearer "):
        token = authorization[7:]
    failure = HTTPException(401, "Sign in again.", headers={"WWW-Authenticate": "Bearer"})
    if not token:
        raise failure
    try:
        payload = jwt.decode(
            token, config.SECRET_KEY, algorithms=["HS256"],
            audience=config.JWT_AUDIENCE, issuer=config.JWT_ISSUER,
            options={"require": ["sub", "sid", "type", "exp", "iat", "iss", "aud"]},
        )
        if payload["type"] != "access":
            raise failure
        session = db.get(AuthSession, payload["sid"])
        user = db.get(Account, payload["sub"])
        if (not session or not user or not user.is_active or session.revoked
                or session.account_id != user.id or session.expires_at <= int(time.time())):
            raise failure
        if from_cookie and session.client_type != "web":
            raise failure
    except (InvalidTokenError, ValueError, TypeError, KeyError):
        raise failure from None
    if from_cookie and request.method not in {"GET", "HEAD", "OPTIONS"}:
        check_csrf(request, session)
    request.state.auth_session_id = session.id
    request.state.auth_from_cookie = from_cookie
    return user


def patient_only(user: Account = Depends(current_user)) -> Account:
    if user.role != "patient":
        raise HTTPException(403, "Patient account required.")
    return user


def caregiver_only(user: Account = Depends(current_user)) -> Account:
    if user.role != "caregiver":
        raise HTTPException(403, "Caregiver account required.")
    return user


def require_patient_access(db: Session, user: Account, patient_id: str) -> None:
    if user.role == "patient" and user.id == patient_id:
        return
    if user.role == "caregiver" and db.scalar(select(CaregiverLink.id).where(
        CaregiverLink.patient_id == patient_id, CaregiverLink.caregiver_id == user.id,
    )):
        return
    raise HTTPException(404, "Patient information not found.")
