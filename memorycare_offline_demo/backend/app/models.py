"""Shared database models, including persistent accounts and revocable sessions."""
import os

from sqlalchemy import Boolean, ForeignKey, Integer, String, UniqueConstraint, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker

from . import config  # Load .env before reading DATABASE_URL.

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./memorycare_server.db")
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
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(20))
    patient_id: Mapped[str | None] = mapped_column(String(80), nullable=True)  # Legacy; not authorization.
    display_name: Mapped[str] = mapped_column(String(120), default="")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    client_type: Mapped[str] = mapped_column(String(10))
    csrf_hash: Mapped[str] = mapped_column(String(64), default="")
    expires_at: Mapped[int] = mapped_column(Integer)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    session_id: Mapped[str] = mapped_column(ForeignKey("auth_sessions.id"), index=True)
    used: Mapped[bool] = mapped_column(Boolean, default=False)


class AuthRateLimit(Base):
    __tablename__ = "auth_rate_limits"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    window: Mapped[int] = mapped_column(Integer)
    count: Mapped[int] = mapped_column(Integer, default=0)


class CaregiverLink(Base):
    __tablename__ = "caregiver_links"
    __table_args__ = (UniqueConstraint("patient_id", "caregiver_id"),)
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    caregiver_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)


class PatientInvite(Base):
    __tablename__ = "patient_invites"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    patient_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    expires_at: Mapped[int] = mapped_column(Integer)
    used: Mapped[bool] = mapped_column(Boolean, default=False)


class Reminder(Base):
    __tablename__ = "reminders"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    title: Mapped[str] = mapped_column(String(160))
    due_at: Mapped[str] = mapped_column(String(40))
    done: Mapped[bool] = mapped_column(Boolean, default=False)
    reminder_type: Mapped[str] = mapped_column(String(40), default="general")
    language_code: Mapped[str] = mapped_column(String(10), default="en")
    voice_text: Mapped[str] = mapped_column(String(500), default="")


class Memory(Base):
    __tablename__ = "memories"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    person_name: Mapped[str] = mapped_column(String(120))
    relationship: Mapped[str] = mapped_column(String(120))
    note: Mapped[str] = mapped_column(String(1000))
    language_code: Mapped[str] = mapped_column(String(10), default="en")


class MemoryMedia(Base):
    __tablename__ = "memory_media"
    id: Mapped[str] = mapped_column(String(180), primary_key=True)
    memory_id: Mapped[str] = mapped_column(String(80), ForeignKey("memories.id"))
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    kind: Mapped[str] = mapped_column(String(20))
    stored_name: Mapped[str] = mapped_column(String(240), unique=True)
    original_name: Mapped[str] = mapped_column(String(240))
    content_type: Mapped[str] = mapped_column(String(100))
    uploaded_at: Mapped[str] = mapped_column(String(40))


class GameResult(Base):
    __tablename__ = "game_results"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))
    game_type: Mapped[str] = mapped_column(String(40))
    correct: Mapped[int] = mapped_column(Integer)
    total: Mapped[int] = mapped_column(Integer)
    seconds: Mapped[int] = mapped_column(Integer)
    played_at: Mapped[str] = mapped_column(String(40))
    level: Mapped[str] = mapped_column(String(20), default="easy")


class AppliedMutation(Base):
    __tablename__ = "applied_mutations"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    patient_id: Mapped[str] = mapped_column(String(80), ForeignKey("accounts.id"))


def get_db():
    with SessionLocal() as db:
        yield db
