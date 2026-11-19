"""Historico simples em SQLite (para revisar respostas depois, no PC)."""
from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

from .models import SolveResponse

_lock = threading.Lock()


class History:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.execute(
            """CREATE TABLE IF NOT EXISTS solves (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   request_id TEXT, created_at TEXT, status TEXT,
                   mode TEXT, verified INTEGER, full_text TEXT, response_json TEXT)"""
        )
        self._conn.commit()

    def add(self, mode: str, resp: SolveResponse) -> None:
        with _lock:
            self._conn.execute(
                "INSERT INTO solves (request_id, created_at, status, mode, verified, full_text, response_json)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    resp.request_id,
                    datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    resp.status,
                    mode,
                    None if resp.verification.passed is None else int(resp.verification.passed),
                    resp.speech.full_text,
                    resp.model_dump_json(),
                ),
            )
            self._conn.commit()

    def recent(self, limit: int = 20) -> list[dict]:
        with _lock:
            rows = self._conn.execute(
                "SELECT request_id, created_at, status, mode, verified, full_text"
                " FROM solves ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        keys = ("request_id", "created_at", "status", "mode", "verified", "full_text")
        return [dict(zip(keys, r)) for r in rows]

    def get(self, request_id: str) -> dict | None:
        with _lock:
            row = self._conn.execute(
                "SELECT response_json FROM solves WHERE request_id = ? ORDER BY id DESC LIMIT 1",
                (request_id,),
            ).fetchone()
        return json.loads(row[0]) if row else None
