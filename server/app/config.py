"""Configuracao lida de variaveis de ambiente (e de server/.env, se existir)."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

SERVER_DIR = Path(__file__).resolve().parent.parent
load_dotenv(SERVER_DIR / ".env")


@dataclass(frozen=True)
class Settings:
    llm_provider: str
    gemini_api_key: str
    gemini_model: str
    bridge_token: str
    verify_timeout_seconds: float
    max_retries_on_verify_fail: int
    history_db: Path

    @classmethod
    def from_env(cls) -> "Settings":
        db = Path(os.getenv("HISTORY_DB", "data/history.db"))
        if not db.is_absolute():
            db = SERVER_DIR / db
        return cls(
            llm_provider=os.getenv("LLM_PROVIDER", "gemini").strip().lower(),
            gemini_api_key=os.getenv("GEMINI_API_KEY", "").strip(),
            gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash").strip(),
            bridge_token=os.getenv("BRIDGE_TOKEN", "").strip(),
            verify_timeout_seconds=float(os.getenv("VERIFY_TIMEOUT_SECONDS", "8")),
            max_retries_on_verify_fail=int(os.getenv("MAX_RETRIES_ON_VERIFY_FAIL", "1")),
            history_db=db,
        )
