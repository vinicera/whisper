"""API FastAPI do Modo Ponte.

Rodar (na pasta server/):  python -m app            (ou scripts/run_server.ps1)
"""
from __future__ import annotations

import hmac
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import verify_sympy
from .config import Settings
from .history import History
from .llm import LLMError, LLMProvider, get_provider
from .models import HealthResponse, SolveRequest, SolveResponse
from .solve import solve, spoken_error

VERSION = "0.1.0"
log = logging.getLogger("whisper")


def create_app(settings: Settings | None = None, provider: LLMProvider | None = None,
               warm_sympy: bool = True) -> FastAPI:
    settings = settings or Settings.from_env()
    state: dict = {"provider": provider}

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if not settings.bridge_token:
            log.warning("BRIDGE_TOKEN vazio: a API está SEM autenticação. Use só em rede confiável.")
        if state["provider"] is None:
            state["provider"] = get_provider(settings)
        state["history"] = History(settings.history_db)
        if warm_sympy:
            await run_in_threadpool(verify_sympy.warmup)
        yield
        verify_sympy.shutdown()

    app = FastAPI(title="Whisper Bridge", version=VERSION, lifespan=lifespan)

    def auth(authorization: str = Header(default="")) -> None:
        if not settings.bridge_token:
            return
        expected = f"Bearer {settings.bridge_token}"
        if not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(status_code=401, detail="token inválido")

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError):
        body = spoken_error("unknown", "error", "BAD_REQUEST",
                            "O aplicativo enviou um pedido inválido ao servidor.", False,
                            str(exc.errors())[:500])
        return JSONResponse(status_code=422, content=body.model_dump())

    @app.get("/v1/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        p = state["provider"]
        return HealthResponse(version=VERSION, llm_provider=p.name, model=p.model)

    @app.post("/v1/solve", response_model=SolveResponse, dependencies=[Depends(auth)])
    async def solve_endpoint(req: SolveRequest):
        try:
            resp = await run_in_threadpool(
                solve, req, state["provider"],
                verify_timeout=settings.verify_timeout_seconds,
                max_retries=settings.max_retries_on_verify_fail,
            )
        except LLMError as exc:  # pragma: no cover - solve ja converte, por garantia
            resp = spoken_error(req.request_id, "error", "LLM_ERROR",
                                "Falha na inteligência artificial.", exc.retryable, str(exc))
        state["history"].add(req.options.mode, resp)
        log.info("solve %s status=%s verified=%s", req.request_id, resp.status, resp.verification.passed)
        code = 200 if resp.status in ("ok", "partial", "unreadable") else 502
        return JSONResponse(status_code=code, content=resp.model_dump())

    @app.get("/v1/history", dependencies=[Depends(auth)])
    def history(limit: int = 20):
        return state["history"].recent(max(1, min(limit, 200)))

    @app.get("/v1/history/{request_id}", dependencies=[Depends(auth)])
    def history_item(request_id: str):
        item = state["history"].get(request_id)
        if item is None:
            raise HTTPException(status_code=404, detail="não encontrado")
        return item

    return app
