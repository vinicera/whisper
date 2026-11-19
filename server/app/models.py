"""Contratos: App iOS <-> Servidor, e Modelo de IA -> Servidor.

A fonte da verdade e este arquivo. `python -m app.export_schema` gera
shared/contract/*.schema.json, que o app Swift espelha em Core/Contract.swift.
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

# --------------------------------------------------------------------------
# App -> Servidor
# --------------------------------------------------------------------------

Mode = Literal["tutor", "resposta", "ditado"]
Detail = Literal["resumo", "passo_a_passo"]
ImageSourceKind = Literal["photo_library", "camera", "glasses_sdk", "upload"]


class ClientInfo(BaseModel):
    app_version: str = "0.0.0"
    device: str = "unknown"
    locale: str = "pt-BR"


class ImagePayload(BaseModel):
    mime: Literal["image/jpeg", "image/png", "image/heic", "image/webp"] = "image/jpeg"
    base64: str = Field(..., min_length=16)
    width: Optional[int] = None
    height: Optional[int] = None
    captured_at: Optional[str] = None
    source: ImageSourceKind = "photo_library"


class SolveOptions(BaseModel):
    mode: Mode = "tutor"
    detail: Detail = "passo_a_passo"
    question_hint: Optional[str] = None
    verify: bool = True
    max_speech_seconds: int = Field(120, ge=10, le=600)


class SolveRequest(BaseModel):
    request_id: str = Field(..., min_length=1, max_length=64)
    client: ClientInfo = ClientInfo()
    image: ImagePayload
    options: SolveOptions = SolveOptions()


# --------------------------------------------------------------------------
# Servidor -> App
# --------------------------------------------------------------------------

SegmentKind = Literal["aviso", "enunciado", "plano", "passo", "resposta"]
Status = Literal["ok", "partial", "unreadable", "error"]


class SpeechSegment(BaseModel):
    id: int
    kind: SegmentKind
    text: str


class Speech(BaseModel):
    full_text: str
    segments: list[SpeechSegment] = []
    lang: str = "pt-BR"
    estimated_seconds: int = 0


class Verification(BaseModel):
    performed: bool = False
    passed: Optional[bool] = None
    engine: str = "sympy"
    notes: Optional[str] = None


class ErrorInfo(BaseModel):
    code: str
    retryable: bool = False
    message: Optional[str] = None


class SolveResponse(BaseModel):
    request_id: str
    status: Status
    speech: Speech
    verification: Verification = Verification()
    error: Optional[ErrorInfo] = None
    debug: dict = {}


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    version: str
    llm_provider: str
    model: str


# --------------------------------------------------------------------------
# Modelo de IA -> Servidor (saida estruturada exigida do LLM)
# --------------------------------------------------------------------------

Operacao = Literal[
    "derivar",
    "integrar_indefinida",
    "integrar_definida",
    "limite",
    "resolver",
    "simplificar",
    "nenhuma",
]


class SympyCheck(BaseModel):
    """Bloco que o servidor executa no SymPy para conferir a resposta."""

    expr: str = Field(..., description="Expressao principal em sintaxe Python/SymPy, com * explicito. Ex.: x**2*sin(x)")
    var: str = Field("x", description="Variavel principal (uma letra)")
    operacao: Operacao
    ordem: Optional[int] = Field(None, description="Ordem da derivada (padrao 1)")
    inferior: Optional[str] = Field(None, description="Limite inferior da integral definida")
    superior: Optional[str] = Field(None, description="Limite superior da integral definida")
    tende_a: Optional[str] = Field(None, description="Ponto do limite. Use oo para infinito")
    lado: Optional[Literal["+", "-", "+-"]] = Field(None, description="Lado do limite")
    resultado: str = Field(..., description="Resultado final em sintaxe SymPy. Em 'resolver', separe as raizes com ;")


class Passo(BaseModel):
    falado: str
    latex: str = ""


class ModelAnswer(BaseModel):
    legivel: bool
    motivo_ilegivel_falado: Optional[str] = None
    enunciado_latex: str = ""
    enunciado_falado: str = ""
    tipo: Literal[
        "derivada", "integral_indefinida", "integral_definida", "limite",
        "serie", "edo", "equacao", "outro",
    ] = "outro"
    plano_falado: str = ""
    sympy: Optional[SympyCheck] = None
    passos: list[Passo] = []
    resposta_falada: str = ""
    resposta_latex: str = ""
