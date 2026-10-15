"""MemoryCare offline-sync API with role isolation, media and caregiver reporting."""

from contextlib import asynccontextmanager
from datetime import datetime, timezone
import os
from pathlib import Path
import secrets
from typing import Literal

from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from urllib.parse import urlsplit
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from pydantic import BaseModel, Field, ValidationError
from sqlalchemy import inspect, select, text, update
from sqlalchemy.orm import Session

from . import config
from .auth import router as auth_router
from .models import (
    Account, AppliedMutation, Base, CaregiverLink, GameResult, Memory, MemoryMedia,
    Reminder, SessionLocal, engine, get_db,
)
from .security import caregiver_only, current_user, patient_only, require_patient_access

MEDIA_DIR = Path(os.getenv("MEDIA_DIR", Path(__file__).resolve().parents[1] / "media"))
MEDIA_DIR.mkdir(parents=True, exist_ok=True)


def _migrate_existing_database() -> None:
    """Add v2 columns without removing any data from the original demo DB."""
    additions = {
        "accounts": {
            "display_name": "VARCHAR(120) DEFAULT ''",
            "is_active": "BOOLEAN DEFAULT true",
        },
        "reminders": {
            "reminder_type": "VARCHAR(40) DEFAULT 'general'",
            "language_code": "VARCHAR(10) DEFAULT 'en'",
            "voice_text": "VARCHAR(500) DEFAULT ''",
        },
        "memories": {"language_code": "VARCHAR(10) DEFAULT 'en'"},
        "game_results": {"level": "VARCHAR(20) DEFAULT 'easy'"},
    }
    schema = inspect(engine)
    with engine.begin() as connection:
        for table_name, columns in additions.items():
            if not schema.has_table(table_name):
                continue
            existing = {column["name"] for column in schema.get_columns(table_name)}
            for column_name, definition in columns.items():
                if column_name not in existing:
                    connection.execute(
                        text(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {definition}")
                    )


class ReminderData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=160)
    due_at: str = Field(min_length=1, max_length=40)
    done: bool = False
    reminder_type: Literal["medicine", "appointment", "activity", "general"] = "general"
    language_code: Literal["en", "kn", "hi"] = "en"
    voice_text: str = Field(default="", max_length=500)


class MemoryData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    person_name: str = Field(min_length=1, max_length=120)
    relationship: str = Field(min_length=1, max_length=120)
    note: str = Field(default="", max_length=1000)
    language_code: Literal["en", "kn", "hi"] = "en"


class GameData(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    game_type: Literal["memory", "attention", "pattern", "routine"]
    correct: int = Field(ge=0, le=100)
    total: int = Field(ge=1, le=100)
    seconds: int = Field(ge=0, le=3600)
    played_at: str = Field(min_length=1, max_length=40)
    level: Literal["easy", "medium", "hard"] = "easy"


class DeleteData(BaseModel):
    id: str = Field(min_length=1, max_length=80)


class Operation(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    kind: Literal["reminder", "memory", "game", "delete_reminder", "delete_memory"]
    payload: dict


class SyncRequest(BaseModel):
    operations: list[Operation] = Field(max_length=100)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    Base.metadata.create_all(engine)
    _migrate_existing_database()
    with SessionLocal.begin() as db:
        # Preserve account IDs and records, but never accept the published demo
        # passwords. A trusted operator must reset each legacy account locally.
        db.execute(update(Account).where(
            ~Account.password_hash.like("$argon2id$%"),
        ).values(is_active=False))
    yield


app = FastAPI(
    title="MemoryCare Platform API",
    description="Offline-first synchronization for reminders, memories and cognitive games.",
    version="2.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None if config.PRODUCTION else '/openapi.json',
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[config.PUBLIC_ORIGIN] if config.PUBLIC_ORIGIN else [],
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-CSRF-Token"],
)
app.include_router(auth_router)
if config.PRODUCTION:
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=[urlsplit(config.PUBLIC_ORIGIN).hostname])


@app.middleware("http")
async def security_headers(request: Request, call_next):
    request.state.csp_nonce = secrets.token_urlsafe(24)
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    nonce = request.state.csp_nonce
    response.headers["Content-Security-Policy"] = (
        f"default-src 'self'; script-src 'self' 'nonce-{nonce}'; "
        f"style-src 'self' 'nonce-{nonce}'; img-src 'self' data:; media-src 'self'; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    )
    if config.PRODUCTION:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


@app.exception_handler(RequestValidationError)
async def safe_validation(_request: Request, exc: RequestValidationError):
    # Pydantic normally includes the submitted input (possibly a password).
    return JSONResponse(status_code=422, content={"detail": [
        {"loc": error["loc"], "msg": error["msg"], "type": error["type"]}
        for error in exc.errors()
    ]})


@app.get("/health")
def health():
    return {"status": "ok", "service": "MemoryCare", "version": "2.1.0"}


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/dashboard")


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)


def _remove_memory_media(db: Session, memory_id: str, patient_id: str) -> None:
    rows = db.scalars(
        select(MemoryMedia).where(
            MemoryMedia.memory_id == memory_id,
            MemoryMedia.patient_id == patient_id,
        )
    ).all()
    for media in rows:
        try:
            (MEDIA_DIR / media.stored_name).unlink(missing_ok=True)
        finally:
            db.delete(media)


@app.post("/sync")
def sync(
    body: SyncRequest,
    user: Account = Depends(patient_only),
    db: Session = Depends(get_db),
):
    acknowledged: list[str] = []
    try:
        for operation in body.operations:
            existing_mutation = db.get(AppliedMutation, operation.id)
            if existing_mutation:
                if existing_mutation.patient_id != user.id:
                    raise HTTPException(409, "Operation ID belongs to another user")
                acknowledged.append(operation.id)
                continue
            try:
                if operation.kind == "reminder":
                    data = ReminderData.model_validate(operation.payload)
                    entity = db.get(Reminder, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Reminder belongs to another user")
                    if entity:
                        for key, value in data.model_dump().items():
                            setattr(entity, key, value)
                    else:
                        db.add(Reminder(patient_id=user.id, **data.model_dump()))
                elif operation.kind == "memory":
                    data = MemoryData.model_validate(operation.payload)
                    entity = db.get(Memory, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Memory belongs to another user")
                    if entity:
                        for key, value in data.model_dump().items():
                            setattr(entity, key, value)
                    else:
                        db.add(Memory(patient_id=user.id, **data.model_dump()))
                elif operation.kind == "game":
                    data = GameData.model_validate(operation.payload)
                    if data.correct > data.total:
                        raise ValueError("correct cannot exceed total")
                    entity = db.get(GameResult, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Game result belongs to another user")
                    if entity:
                        raise HTTPException(409, "Game result is immutable")
                    db.add(GameResult(patient_id=user.id, **data.model_dump()))
                elif operation.kind == "delete_reminder":
                    data = DeleteData.model_validate(operation.payload)
                    entity = db.get(Reminder, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Reminder belongs to another user")
                    if entity:
                        db.delete(entity)
                else:
                    data = DeleteData.model_validate(operation.payload)
                    entity = db.get(Memory, data.id)
                    if entity and entity.patient_id != user.id:
                        raise HTTPException(409, "Memory belongs to another user")
                    if entity:
                        _remove_memory_media(db, data.id, user.id)
                        db.delete(entity)
            except (ValidationError, ValueError) as exc:
                raise HTTPException(
                    422, f"Invalid {operation.kind} operation: {exc}"
                ) from exc
            db.add(AppliedMutation(id=operation.id, patient_id=user.id))
            db.flush()
            acknowledged.append(operation.id)
        db.commit()
    except Exception:
        db.rollback()
        raise
    return {"acknowledged": acknowledged}


_MEDIA_TYPES = {
    "photo": {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
    },
    "audio": {
        "audio/mp4": ".m4a",
        "audio/m4a": ".m4a",
        "audio/aac": ".aac",
        "audio/mpeg": ".mp3",
        "audio/wav": ".wav",
        "audio/x-wav": ".wav",
        "application/octet-stream": ".m4a",
    },
}


@app.post("/memories/{memory_id}/media/{kind}")
async def upload_memory_media(
    memory_id: str,
    kind: Literal["photo", "audio"],
    file: UploadFile = File(...),
    user: Account = Depends(patient_only),
    db: Session = Depends(get_db),
):
    memory = db.get(Memory, memory_id)
    if not memory or memory.patient_id != user.id:
        raise HTTPException(404, "Memory not found")
    content_type = (file.content_type or "application/octet-stream").lower()
    extension = _MEDIA_TYPES[kind].get(content_type)
    if content_type == "application/octet-stream" and file.filename:
        supplied_extension = Path(file.filename).suffix.lower()
        if supplied_extension in set(_MEDIA_TYPES[kind].values()):
            extension = supplied_extension
    if not extension:
        raise HTTPException(415, f"Unsupported {kind} format")
    if content_type == 'application/octet-stream':
        content_type = {'.jpg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
                        '.m4a': 'audio/mp4', '.aac': 'audio/aac', '.mp3': 'audio/mpeg', '.wav': 'audio/wav'}[extension]
    content = await file.read(8 * 1024 * 1024 + 1)
    if len(content) > 8 * 1024 * 1024:
        raise HTTPException(413, "Media must be 8 MB or smaller")
    # Never put a caller-supplied record ID or filename into a filesystem path.
    stored_name = f"{secrets.token_hex(24)}{extension}"
    destination = MEDIA_DIR / stored_name
    existing = db.get(MemoryMedia, f"{memory_id}:{kind}")
    old_name = existing.stored_name if existing else None
    destination.write_bytes(content)
    try:
        if existing:
            existing.stored_name = stored_name
            existing.original_name = file.filename or stored_name
            existing.content_type = content_type
            existing.uploaded_at = datetime.now(timezone.utc).isoformat()
        else:
            db.add(
                MemoryMedia(
                    id=f"{memory_id}:{kind}",
                    memory_id=memory_id,
                    patient_id=user.id,
                    kind=kind,
                    stored_name=stored_name,
                    original_name=file.filename or stored_name,
                    content_type=content_type,
                    uploaded_at=datetime.now(timezone.utc).isoformat(),
                )
            )
        db.commit()
    except Exception:
        db.rollback()
        destination.unlink(missing_ok=True)
        raise
    if old_name and old_name != stored_name:
        (MEDIA_DIR / old_name).unlink(missing_ok=True)
    return {"status": "stored", "kind": kind, "url": f"/media/{stored_name}"}


@app.get("/media/{stored_name}")
def private_media(stored_name: str, user: Account = Depends(current_user), db: Session = Depends(get_db)):
    media = db.scalar(select(MemoryMedia).where(MemoryMedia.stored_name == stored_name))
    if not media:
        raise HTTPException(404, "Media not found")
    require_patient_access(db, user, media.patient_id)
    path = (MEDIA_DIR / media.stored_name).resolve()
    if path.parent != MEDIA_DIR.resolve() or not path.is_file():
        raise HTTPException(404, "Media not found")
    return FileResponse(path, media_type=media.content_type,
                        headers={"Content-Disposition": "inline", "Cache-Control": "no-store"})


@app.get("/caregiver/summary")
def caregiver_summary(
    patient_id: str | None = None,
    user: Account = Depends(caregiver_only),
    db: Session = Depends(get_db),
):
    if patient_id is None:
        patient_id = db.scalar(select(CaregiverLink.patient_id).where(CaregiverLink.caregiver_id == user.id))
        if not patient_id:
            raise HTTPException(404, "No patient linked. Ask the patient for a linking code.")
    require_patient_access(db, user, patient_id)
    reminders = db.scalars(
        select(Reminder)
        .where(Reminder.patient_id == patient_id)
        .order_by(Reminder.done, Reminder.due_at)
    ).all()
    memories = db.scalars(
        select(Memory).where(Memory.patient_id == patient_id).order_by(Memory.person_name)
    ).all()
    games = db.scalars(
        select(GameResult)
        .where(GameResult.patient_id == patient_id)
        .order_by(GameResult.played_at.desc())
    ).all()
    media_rows = db.scalars(
        select(MemoryMedia).where(MemoryMedia.patient_id == patient_id)
    ).all()
    media = {(row.memory_id, row.kind): f"/media/{row.stored_name}" for row in media_rows}
    correct = sum(game.correct for game in games)
    total = sum(game.total for game in games)
    return {
        "patient_id": patient_id,
        "patient_name": (db.get(Account, patient_id).display_name or patient_id),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stats": {
            "pending_reminders": sum(not reminder.done for reminder in reminders),
            "completed_reminders": sum(reminder.done for reminder in reminders),
            "memories": len(memories),
            "games": len(games),
            "accuracy": round(correct * 100 / total) if total else 0,
        },
        "reminders": [
            {
                "id": reminder.id,
                "title": reminder.title,
                "due_at": reminder.due_at,
                "done": reminder.done,
                "reminder_type": reminder.reminder_type or "general",
                "language_code": reminder.language_code or "en",
                "voice_text": reminder.voice_text or "",
            }
            for reminder in reminders
        ],
        "memories": [
            {
                "id": memory.id,
                "person_name": memory.person_name,
                "relationship": memory.relationship,
                "note": memory.note,
                "language_code": memory.language_code or "en",
                "photo_url": media.get((memory.id, "photo")),
                "audio_url": media.get((memory.id, "audio")),
            }
            for memory in memories
        ],
        "games": [
            {
                "id": game.id,
                "game_type": game.game_type,
                "correct": game.correct,
                "total": game.total,
                "seconds": game.seconds,
                "played_at": game.played_at,
                "level": game.level or "easy",
            }
            for game in games
        ],
    }


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request):
    content = Path(__file__).with_name("dashboard.html").read_text(encoding="utf-8")
    nonce = request.state.csp_nonce
    return content.replace("<script>", f'<script nonce="{nonce}">').replace("<style>", f'<style nonce="{nonce}">')
