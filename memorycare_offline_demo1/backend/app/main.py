"""Offline-sync demo API. All accepted mutations are transactional and idempotent."""
import base64
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field, ValidationError
from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker


DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./memorycare_server.db")
SECRET = os.getenv("DEMO_SECRET", "local-demo-secret-change-me").encode()
engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {},
    pool_pre_ping=True,
)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class Account(Base):
    __tablename__ = "accounts"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    username: Mapped[str] = mapped_column(String(80), unique=True)
    password_hash: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(20))
    patient_id: Mapped[str | None] = mapped_column(String(80), nullable=True)


class Reminder(Base):
    __tablename__ = "reminders"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    title: Mapped[str] = mapped_column(String(160))
    due_at: Mapped[str] = mapped_column(String(40))
    done: Mapped[bool] = mapped_column(Boolean, default=False)


class Memory(Base):
    __tablename__ = "memories"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    person_name: Mapped[str] = mapped_column(String(120))
    relationship: Mapped[str] = mapped_column(String(120))
    note: Mapped[str] = mapped_column(String(400))


class GameResult(Base):
    __tablename__ = "game_results"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    game_type: Mapped[str] = mapped_column(String(40))
    correct: Mapped[int] = mapped_column(Integer)
    total: Mapped[int] = mapped_column(Integer)
    seconds: Mapped[int] = mapped_column(Integer)
    played_at: Mapped[str] = mapped_column(String(40))


class AppliedMutation(Base):
    __tablename__ = "applied_mutations"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 250_000)
    return salt.hex() + ":" + digest.hex()


def check_password(password: str, stored: str) -> bool:
    salt_hex, digest_hex = stored.split(":")
    result = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), 250_000)
    return hmac.compare_digest(result, bytes.fromhex(digest_hex))


def encode_token(account: Account) -> str:
    data = json.dumps(
        {"sub": account.id, "exp": int((datetime.now(timezone.utc) + timedelta(days=7)).timestamp())},
        separators=(",", ":"),
    ).encode()
    body = base64.urlsafe_b64encode(data).decode().rstrip("=")
    signature = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()
    return body + "." + signature


def get_db():
    with SessionLocal() as db:
        yield db


def current_user(
    authorization: Annotated[str | None, Header()] = None,
    db: Session = Depends(get_db),
) -> Account:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Login required")
    try:
        body, sig = authorization[7:].split(".")
        expected = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, sig):
            raise ValueError("Invalid signature")
        payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        if payload["exp"] < int(datetime.now(timezone.utc).timestamp()):
            raise ValueError("Expired token")
        account = db.get(Account, payload["sub"])
    except (ValueError, KeyError, TypeError, UnicodeError):
        account = None
    if not account:
        raise HTTPException(401, "Invalid or expired login; reconnect and sign in")
    return account


def patient_only(user: Account = Depends(current_user)) -> Account:
    if user.role != "patient":
        raise HTTPException(403, "Patient account required")
    return user


def caregiver_only(user: Account = Depends(current_user)) -> Account:
    if user.role != "caregiver":
        raise HTTPException(403, "Caregiver account required")
    return user


class LoginRequest(BaseModel):
    username: str
    password: str


class ReminderData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=160)
    due_at: str = Field(min_length=1, max_length=40)
    done: bool = False


class MemoryData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    person_name: str = Field(min_length=1, max_length=120)
    relationship: str = Field(min_length=1, max_length=120)
    note: str = Field(max_length=400)


class GameData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    game_type: Literal["memory", "attention", "pattern", "routine"]
    correct: int = Field(ge=0, le=100)
    total: int = Field(ge=1, le=100)
    seconds: int = Field(ge=0, le=3600)
    played_at: str = Field(min_length=1, max_length=40)


class Operation(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    kind: Literal["reminder", "memory", "game"]
    payload: dict


class SyncRequest(BaseModel):
    operations: list[Operation] = Field(max_length=100)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    Base.metadata.create_all(engine)
    with SessionLocal.begin() as db:
        if db.get(Account, "patient-1") is None:
            db.add(Account(id="patient-1", username="patient", password_hash=hash_password("demo1234"), role="patient"))
        if db.get(Account, "caregiver-1") is None:
            db.add(Account(
                id="caregiver-1", username="caregiver", password_hash=hash_password("demo1234"),
                role="caregiver", patient_id="patient-1",
            ))
    yield


app = FastAPI(title="MemoryCare Offline Demo", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/auth/login")
def login(body: LoginRequest, db: Session = Depends(get_db)):
    account = db.scalar(select(Account).where(Account.username == body.username))
    if not account or not check_password(body.password, account.password_hash):
        raise HTTPException(401, "Invalid login")
    return {"access_token": encode_token(account), "role": account.role, "user_id": account.id}


@app.post("/sync")
def sync(body: SyncRequest, user: Account = Depends(patient_only), db: Session = Depends(get_db)):
    # A whole batch commits or rolls back. Only acknowledge operations AFTER commit.
    acknowledged = []
    try:
        for op in body.operations:
            existing = db.get(AppliedMutation, op.id)
            if existing:
                if existing.patient_id != user.id:
                    raise HTTPException(409, "Operation ID belongs to another user")
                acknowledged.append(op.id)
                continue
            try:
                if op.kind == "reminder":
                    data = ReminderData.model_validate(op.payload)
                    entity = db.get(Reminder, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Reminder belongs to another user")
                    if entity:
                        entity.title, entity.due_at, entity.done = data.title, data.due_at, data.done
                    else:
                        db.add(Reminder(patient_id=user.id, **data.model_dump()))
                elif op.kind == "memory":
                    data = MemoryData.model_validate(op.payload)
                    entity = db.get(Memory, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Memory belongs to another user")
                    if entity:
                        entity.person_name, entity.relationship, entity.note = (
                            data.person_name, data.relationship, data.note
                        )
                    else:
                        db.add(Memory(patient_id=user.id, **data.model_dump()))
                else:
                    data = GameData.model_validate(op.payload)
                    if data.correct > data.total:
                        raise ValueError("correct cannot exceed total")
                    entity = db.get(GameResult, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Game result belongs to another user")
                    if entity:
                        raise HTTPException(409, "Game result is immutable")
                    db.add(GameResult(patient_id=user.id, **data.model_dump()))
            except (ValidationError, ValueError) as exc:
                raise HTTPException(422, f"Invalid {op.kind} operation: {exc}") from exc
            db.add(AppliedMutation(id=op.id, patient_id=user.id))
            # Flush makes repeated IDs within the SAME request idempotent too.
            db.flush()
            acknowledged.append(op.id)
        db.commit()
    except Exception:
        db.rollback()
        raise
    return {"acknowledged": acknowledged}


@app.get("/caregiver/summary")
def caregiver_summary(user: Account = Depends(caregiver_only), db: Session = Depends(get_db)):
    patient_id = user.patient_id
    reminders = db.scalars(select(Reminder).where(Reminder.patient_id == patient_id)).all()
    memories = db.scalars(select(Memory).where(Memory.patient_id == patient_id)).all()
    games = db.scalars(select(GameResult).where(GameResult.patient_id == patient_id)).all()
    return {
        "patient_id": patient_id,
        "reminders": [
            {"title": r.title, "due_at": r.due_at, "done": r.done} for r in reminders
        ],
        "memories": [
            {"person_name": m.person_name, "relationship": m.relationship, "note": m.note}
            for m in memories
        ],
        "games": [
            {"game_type": g.game_type, "correct": g.correct, "total": g.total, "seconds": g.seconds,
             "played_at": g.played_at} for g in games
        ],
    }


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard():
    return Path(__file__).with_name("dashboard.html").read_text(encoding="utf-8")
