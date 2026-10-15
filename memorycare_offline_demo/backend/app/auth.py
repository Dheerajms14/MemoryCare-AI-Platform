"""Individual accounts, rotating refresh tokens, and consent-based caregiver links."""
import secrets
import time
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import config
from .models import Account, AuthSession, CaregiverLink, PatientInvite, RefreshToken, get_db
from .security import (
    DUMMY_HASH, access_token, caregiver_only, check_csrf, check_password,
    check_web_origin, current_user, digest, password_hasher, patient_only,
    require_https, throttle, validate_password,
)

router = APIRouter(tags=["Authentication and patient access"])


class StrictForm(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LoginRequest(StrictForm):
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=128)
    role: Literal["patient", "caregiver"] | None = None


class RegisterRequest(StrictForm):
    display_name: str = Field(min_length=2, max_length=120)
    username: str = Field(min_length=3, max_length=40, pattern=r"^[a-zA-Z0-9_.-]+$")
    password: str = Field(min_length=15, max_length=128)
    role: Literal["patient", "caregiver"]

    @field_validator("username")
    @classmethod
    def normalize_username(cls, value: str) -> str:
        return value.lower()

    @field_validator("display_name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 2:
            raise ValueError("Enter your full name.")
        return value

    @model_validator(mode="after")
    def strong_password(self):
        validate_password(self.password, self.username)
        return self


class RefreshRequest(StrictForm):
    refresh_token: str = Field(min_length=20, max_length=256)


class ChangePasswordRequest(StrictForm):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=15, max_length=128)


class LinkRequest(StrictForm):
    code: str = Field(min_length=24, max_length=24, pattern=r"^[0-9a-fA-F]+$")


def public_profile(user: Account) -> dict:
    return {"user_id": user.id, "username": user.username, "role": user.role,
            "display_name": user.display_name or user.username}


def _authenticate(body: LoginRequest, request: Request, db: Session) -> Account:
    require_https(request)
    username = body.username.strip().lower()
    throttle(db, request, "login-ip", 50, 900)
    throttle(db, request, "login-name", 10, 900, username, per_peer=False)
    user = db.scalar(select(Account).where(Account.username == username))
    verified = check_password(body.password, user.password_hash if user and user.is_active else DUMMY_HASH)
    if not user or not user.is_active or not verified or (body.role and body.role != user.role):
        raise HTTPException(401, "Invalid username, password, or account type.")
    return user


def _tokens(db: Session, user: Account, session: AuthSession) -> dict:
    refresh = secrets.token_urlsafe(48)
    db.add(RefreshToken(digest=digest(refresh), session_id=session.id, used=False))
    db.flush()
    return {
        "access_token": access_token(user, session), "refresh_token": refresh,
        "token_type": "bearer", "expires_in": config.ACCESS_SECONDS,
        "refresh_expires_at": session.expires_at, **public_profile(user),
    }


def _new_session(db: Session, user: Account, client_type: str) -> tuple[dict, str]:
    csrf = secrets.token_urlsafe(32) if client_type == "web" else ""
    session = AuthSession(
        id=str(uuid4()), account_id=user.id, client_type=client_type,
        csrf_hash=digest(csrf) if csrf else "", revoked=False,
        expires_at=int(time.time()) + config.SESSION_SECONDS,
    )
    db.add(session)
    db.flush()
    reply = _tokens(db, user, session)
    db.commit()
    return reply, csrf


def _set_cookies(response: Response, tokens: dict, csrf: str) -> None:
    remaining = max(0, tokens["refresh_expires_at"] - int(time.time()))
    common = {"secure": config.PRODUCTION, "samesite": "strict"}
    response.set_cookie(config.ACCESS_COOKIE, tokens["access_token"],
                        httponly=True, max_age=min(config.ACCESS_SECONDS, remaining), path="/", **common)
    response.set_cookie(config.REFRESH_COOKIE, tokens["refresh_token"],
                        httponly=True, max_age=remaining, path="/auth/web", **common)
    response.set_cookie(config.CSRF_COOKIE, csrf, httponly=False, max_age=remaining, path="/", **common)


def _clear_cookies(response: Response) -> None:
    for name, path in [(config.ACCESS_COOKIE, "/"), (config.REFRESH_COOKIE, "/auth/web"), (config.CSRF_COOKIE, "/")]:
        response.delete_cookie(name, path=path, secure=config.PRODUCTION, samesite="strict")


def _rotate(db: Session, request: Request, raw: str, client_type: str) -> tuple[dict, str]:
    require_https(request)
    throttle(db, request, "refresh", 120, 900)
    token = db.get(RefreshToken, digest(raw))
    session = db.get(AuthSession, token.session_id) if token else None
    user = db.get(Account, session.account_id) if session else None
    failure = HTTPException(401, "Session expired. Sign in again.")
    if (not token or not session or not user or not user.is_active or session.revoked
            or session.expires_at <= int(time.time()) or session.client_type != client_type):
        raise failure
    if client_type == "web":
        check_csrf(request, session)
    # A refresh token can be consumed once, even when requests race.
    consumed = db.execute(update(RefreshToken).where(
        RefreshToken.digest == token.digest, RefreshToken.used.is_(False),
    ).values(used=True)).rowcount
    if not consumed:
        db.execute(update(AuthSession).where(AuthSession.id == session.id).values(revoked=True))
        db.commit()
        raise failure  # Reuse revokes the entire token family.
    csrf = secrets.token_urlsafe(32) if client_type == "web" else ""
    if csrf:
        session.csrf_hash = digest(csrf)
    reply = _tokens(db, user, session)
    db.commit()
    return reply, csrf


@router.post("/auth/register", status_code=201)
def register(body: RegisterRequest, request: Request, db: Session = Depends(get_db)):
    require_https(request)
    throttle(db, request, "register", 12, 3600)
    user = Account(
        id=str(uuid4()), username=body.username, display_name=body.display_name,
        password_hash=password_hasher.hash(body.password), role=body.role, is_active=True,
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "That username is unavailable. Choose another.") from None
    return public_profile(user)


@router.post("/auth/login")
def login(body: LoginRequest, request: Request, db: Session = Depends(get_db)):
    user = _authenticate(body, request, db)
    return _new_session(db, user, "mobile")[0]


@router.post("/auth/refresh")
def refresh(body: RefreshRequest, request: Request, db: Session = Depends(get_db)):
    return _rotate(db, request, body.refresh_token, "mobile")[0]


@router.post("/auth/web/login")
def web_login(body: LoginRequest, request: Request, response: Response, db: Session = Depends(get_db)):
    check_web_origin(request)
    if body.role not in {None, "caregiver"}:
        raise HTTPException(401, "Use your caregiver account.")
    body.role = "caregiver"
    user = _authenticate(body, request, db)
    tokens, csrf = _new_session(db, user, "web")
    _set_cookies(response, tokens, csrf)
    return public_profile(user)  # Browser JavaScript never receives a bearer or refresh token.


@router.post("/auth/web/refresh")
def web_refresh(request: Request, response: Response, db: Session = Depends(get_db)):
    raw = request.cookies.get(config.REFRESH_COOKIE, "")
    tokens, csrf = _rotate(db, request, raw, "web")
    _set_cookies(response, tokens, csrf)
    return {"status": "refreshed"}


@router.get("/auth/me")
def me(user: Account = Depends(current_user)):
    return public_profile(user)


@router.post("/auth/logout")
def logout(request: Request, response: Response, user: Account = Depends(current_user), db: Session = Depends(get_db)):
    db.execute(update(AuthSession).where(AuthSession.id == request.state.auth_session_id,
                                         AuthSession.account_id == user.id).values(revoked=True))
    db.commit()
    _clear_cookies(response)
    return {"status": "signed out"}


@router.post("/auth/change-password")
def change_password(body: ChangePasswordRequest, request: Request, response: Response,
                    user: Account = Depends(current_user), db: Session = Depends(get_db)):
    throttle(db, request, "password-change", 10, 900, user.id)
    if not check_password(body.current_password, user.password_hash):
        raise HTTPException(400, "Current password is incorrect.")
    try:
        validate_password(body.new_password, user.username)
    except ValueError as error:
        raise HTTPException(422, str(error)) from None
    if body.new_password == body.current_password:
        raise HTTPException(422, "Choose a different passphrase.")
    user.password_hash = password_hasher.hash(body.new_password)
    db.execute(update(AuthSession).where(AuthSession.account_id == user.id).values(revoked=True))
    db.commit()
    _clear_cookies(response)
    return {"status": "Password changed. Sign in again on every device."}


@router.post("/patients/invite", status_code=201)
def create_invite(request: Request, user: Account = Depends(patient_only), db: Session = Depends(get_db)):
    throttle(db, request, "invite-create", 20, 3600, user.id)
    # Generating a new code invalidates older unused codes for this patient.
    db.execute(delete(PatientInvite).where(PatientInvite.patient_id == user.id))
    code = secrets.token_hex(12)
    expires = int(time.time()) + 600
    db.add(PatientInvite(digest=digest(code), patient_id=user.id, expires_at=expires, used=False))
    db.commit()
    return {"code": code, "expires_in": 600}


@router.post("/caregiver/link")
def redeem_invite(body: LinkRequest, request: Request, user: Account = Depends(caregiver_only), db: Session = Depends(get_db)):
    throttle(db, request, "invite-redeem", 10, 900, user.id)
    invite = db.get(PatientInvite, digest(body.code.lower()))
    if not invite or invite.used or invite.expires_at <= int(time.time()):
        raise HTTPException(400, "Invalid or expired linking code.")
    changed = db.execute(update(PatientInvite).where(
        PatientInvite.digest == invite.digest, PatientInvite.used.is_(False),
        PatientInvite.expires_at > int(time.time()),
    ).values(used=True)).rowcount
    if not changed:
        db.rollback()
        raise HTTPException(400, "Invalid or expired linking code.")
    existing = db.scalar(select(CaregiverLink).where(
        CaregiverLink.patient_id == invite.patient_id, CaregiverLink.caregiver_id == user.id,
    ))
    if not existing:
        db.add(CaregiverLink(id=str(uuid4()), patient_id=invite.patient_id, caregiver_id=user.id))
    db.commit()
    return {"status": "linked", "patient_id": invite.patient_id}


@router.get("/caregiver/patients")
def linked_patients(user: Account = Depends(caregiver_only), db: Session = Depends(get_db)):
    users = db.scalars(select(Account).join(CaregiverLink, CaregiverLink.patient_id == Account.id).where(
        CaregiverLink.caregiver_id == user.id, Account.is_active.is_(True),
    ).order_by(Account.display_name, Account.username)).all()
    return {"patients": [public_profile(account) for account in users]}


@router.get("/patients/caregivers")
def linked_caregivers(user: Account = Depends(patient_only), db: Session = Depends(get_db)):
    users = db.scalars(select(Account).join(CaregiverLink, CaregiverLink.caregiver_id == Account.id).where(
        CaregiverLink.patient_id == user.id,
    )).all()
    return {"caregivers": [public_profile(account) for account in users]}


@router.delete("/patients/caregivers/{caregiver_id}")
def revoke_caregiver(caregiver_id: str, user: Account = Depends(patient_only), db: Session = Depends(get_db)):
    db.execute(delete(CaregiverLink).where(CaregiverLink.patient_id == user.id,
                                         CaregiverLink.caregiver_id == caregiver_id))
    db.commit()
    return {"status": "access removed"}
