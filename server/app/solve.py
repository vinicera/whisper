"""Pipeline: imagem -> modelo -> verificacao SymPy -> fala limpa."""
from __future__ import annotations

import base64
import binascii
import time
from typing import Callable, Optional

from .llm import LLMError, LLMProvider
from .models import (
    ErrorInfo, ModelAnswer, SolveRequest, SolveResponse, Speech, SpeechSegment, Verification,
)
from .sanitizer import find_forbidden, sanitize_for_speech
from .verify_sympy import VerifyResult, verify

MAX_IMAGE_BYTES = 8 * 1024 * 1024
WORDS_PER_SECOND = 2.5  # ~150 palavras/min, ritmo normal do AVSpeechSynthesizer

Verifier = Callable[[dict, float], VerifyResult]


def spoken_error(request_id: str, status: str, code: str, text: str,
                 retryable: bool, message: Optional[str] = None) -> SolveResponse:
    return SolveResponse(
        request_id=request_id,
        status=status,  # type: ignore[arg-type]
        speech=Speech(full_text=text, segments=[SpeechSegment(id=1, kind="aviso", text=text)],
                      estimated_seconds=_estimate(text)),
        error=ErrorInfo(code=code, retryable=retryable, message=message),
    )


def _estimate(text: str) -> int:
    return max(1, round(len(text.split()) / WORDS_PER_SECOND))


def _decode_image(b64: str) -> bytes:
    if "," in b64[:100] and b64.startswith("data:"):
        b64 = b64.split(",", 1)[1]
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("imagem em base64 inválida") from exc
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError(f"imagem maior que {MAX_IMAGE_BYTES // (1024 * 1024)} MB")
    return data


def _clean(text: str) -> str:
    return sanitize_for_speech(text)


def _final_answer_text(answer: ModelAnswer, vr: Optional[VerifyResult]) -> str:
    text = _clean(answer.resposta_falada)
    if text and not find_forbidden(text):
        return text
    # O texto do modelo veio sujo ou vazio: gera a fala a partir do SymPy.
    if answer.sympy:
        from .spoken_math import to_speech
        from .verify_sympy import parse_safe_unevaluated

        source = (vr.canonical if vr and vr.canonical else None) or answer.sympy.resultado
        try:
            expr = parse_safe_unevaluated(source.split(";")[0])
            return "A resposta final é " + to_speech(expr) + "."
        except Exception:  # noqa: BLE001
            pass
    return text or "Não consegui formular a resposta final."


def build_segments(answer: ModelAnswer, mode: str, vr: Optional[VerifyResult]) -> list[SpeechSegment]:
    segs: list[tuple[str, str]] = []
    if vr and vr.performed and vr.passed is False:
        segs.append(("aviso", "Atenção: o verificador matemático não confirmou este resultado. Confira com cuidado."))
    if answer.enunciado_falado:
        segs.append(("enunciado", _clean(answer.enunciado_falado)))
    if mode != "ditado":
        if mode == "tutor" and answer.plano_falado:
            segs.append(("plano", _clean(answer.plano_falado)))
        passos = answer.passos if mode == "tutor" else answer.passos[:2]
        for p in passos:
            if p.falado.strip():
                segs.append(("passo", _clean(p.falado)))
        segs.append(("resposta", _final_answer_text(answer, vr)))
    return [SpeechSegment(id=i + 1, kind=k, text=t) for i, (k, t) in enumerate(segs) if t]  # type: ignore[arg-type]


def solve(req: SolveRequest, provider: LLMProvider, *, verify_timeout: float = 8.0,
          max_retries: int = 1, verifier: Verifier = verify) -> SolveResponse:
    t0 = time.perf_counter()
    lat: dict[str, int] = {}

    try:
        image = _decode_image(req.image.base64)
    except ValueError as exc:
        return spoken_error(req.request_id, "error", "BAD_IMAGE",
                            "A imagem chegou corrompida. Tente enviar de novo.", True, str(exc))

    feedback: Optional[str] = None
    answer: Optional[ModelAnswer] = None
    vr: Optional[VerifyResult] = None
    attempts = 0
    for attempts in range(1, max_retries + 2):
        t = time.perf_counter()
        try:
            answer = provider.analyze(image, req.image.mime, req.options, feedback)
        except LLMError as exc:
            return spoken_error(req.request_id, "error", "LLM_ERROR",
                                "O servidor não conseguiu falar com a inteligência artificial. Tente de novo.",
                                exc.retryable, str(exc))
        lat[f"vision_{attempts}"] = round((time.perf_counter() - t) * 1000)

        if not answer.legivel:
            text = _clean(answer.motivo_ilegivel_falado or "") or \
                "Não consegui ler a questão. Tente fotografar mais perto e com mais luz."
            return spoken_error(req.request_id, "unreadable", "IMAGE_UNREADABLE", text, True)

        if not (req.options.verify and answer.sympy and req.options.mode != "ditado"):
            vr = None
            break
        t = time.perf_counter()
        vr = verifier(answer.sympy.model_dump(), verify_timeout)
        lat[f"verify_{attempts}"] = round((time.perf_counter() - t) * 1000)
        if not (vr.performed and vr.passed is False):
            break
        feedback = vr.notes or "o resultado não confere"

    assert answer is not None
    segments = build_segments(answer, req.options.mode, vr)
    full = " ".join(s.text for s in segments)
    lat["total"] = round((time.perf_counter() - t0) * 1000)

    status = "ok"
    if vr and vr.performed and vr.passed is False:
        status = "partial"

    return SolveResponse(
        request_id=req.request_id,
        status=status,  # type: ignore[arg-type]
        speech=Speech(full_text=full, segments=segments, estimated_seconds=_estimate(full)),
        verification=Verification(
            performed=bool(vr and vr.performed),
            passed=vr.passed if vr else None,
            notes=vr.notes if vr else "verificação não aplicável",
        ),
        debug={
            "transcribed_latex": answer.enunciado_latex,
            "final_latex": answer.resposta_latex,
            "sympy": answer.sympy.model_dump() if answer.sympy else None,
            "sympy_canonical": vr.canonical if vr else None,
            "attempts": attempts,
            "model": f"{provider.name}:{provider.model}",
            "latency_ms": lat,
            "leftover_symbols": find_forbidden(full),
        },
    )
