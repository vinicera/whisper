"""Provedores de IA multimodal. Todos devolvem um `ModelAnswer` validado."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Optional, Protocol

from .config import Settings
from .models import ModelAnswer, Passo, SolveOptions, SympyCheck

PROMPT_PATH = Path(__file__).parent / "prompts" / "system_pt.md"


@lru_cache(maxsize=1)
def system_prompt() -> str:
    return PROMPT_PATH.read_text(encoding="utf-8")


def build_user_message(options: SolveOptions, feedback: Optional[str]) -> str:
    lines = [
        f"Modo: {options.mode}",
        f"Detalhe: {options.detail}",
        f"Questão indicada: {options.question_hint or 'nenhuma'}",
        f"Duração máxima da fala: {options.max_speech_seconds} segundos.",
        "Responda somente com o JSON no esquema fornecido.",
    ]
    if feedback:
        lines.append(
            "ATENÇÃO: sua tentativa anterior foi conferida no SymPy e falhou: "
            f"{feedback}. Refaça os cálculos com cuidado e corrija passos e resposta."
        )
    return "\n".join(lines)


class LLMError(RuntimeError):
    def __init__(self, message: str, retryable: bool = True):
        super().__init__(message)
        self.retryable = retryable


class LLMProvider(Protocol):
    name: str
    model: str

    def analyze(self, image: bytes, mime: str, options: SolveOptions,
                feedback: Optional[str] = None) -> ModelAnswer: ...


class GeminiProvider:
    name = "gemini"

    def __init__(self, api_key: str, model: str):
        if not api_key:
            raise LLMError("GEMINI_API_KEY não configurada no server/.env", retryable=False)
        from google import genai

        self._client = genai.Client(api_key=api_key)
        self.model = model

    def analyze(self, image: bytes, mime: str, options: SolveOptions,
                feedback: Optional[str] = None) -> ModelAnswer:
        from google.genai import types

        try:
            resp = self._client.models.generate_content(
                model=self.model,
                contents=[
                    types.Part.from_bytes(data=image, mime_type=mime),
                    build_user_message(options, feedback),
                ],
                config=types.GenerateContentConfig(
                    system_instruction=system_prompt(),
                    response_mime_type="application/json",
                    response_schema=ModelAnswer,
                    temperature=0.2,
                ),
            )
        except Exception as exc:  # noqa: BLE001 - erros de rede/cota do SDK
            raise LLMError(f"falha ao chamar o Gemini: {type(exc).__name__}: {exc}") from exc
        if not resp.text:
            raise LLMError("o Gemini retornou resposta vazia")
        try:
            return ModelAnswer.model_validate_json(resp.text)
        except ValueError as exc:
            raise LLMError(f"JSON inválido do modelo: {exc}") from exc


class FakeProvider:
    """Resposta fixa para testes e para validar o app sem gastar cota.

    `wrong_first=True` erra de propósito na primeira chamada, para exercitar
    o ciclo de re-geração após falha na verificação.
    """

    name = "fake"
    model = "fake-v1"

    def __init__(self, wrong_first: bool = False, unreadable: bool = False):
        self.wrong_first = wrong_first
        self.unreadable = unreadable
        self.calls = 0

    def analyze(self, image: bytes, mime: str, options: SolveOptions,
                feedback: Optional[str] = None) -> ModelAnswer:
        self.calls += 1
        if self.unreadable:
            return ModelAnswer(
                legivel=False,
                motivo_ilegivel_falado="Não consegui ler a questão. Aproxime a câmera e melhore a luz.",
            )
        wrong = self.wrong_first and self.calls == 1
        resultado = "2*x*sin(x)" if wrong else "2*x*sin(x) + x**2*cos(x)"
        return ModelAnswer(
            legivel=True,
            enunciado_latex=r"\frac{d}{dx}\left(x^2 \sin x\right)",
            enunciado_falado="Calcule a derivada em relação a x de x ao quadrado vezes seno de x.",
            tipo="derivada",
            plano_falado="Vamos usar a regra do produto.",
            sympy=SympyCheck(expr="x**2*sin(x)", var="x", operacao="derivar", resultado=resultado),
            passos=[
                Passo(falado="A regra do produto diz que a derivada de f vezes g é f linha g, mais f g linha.",
                      latex="(fg)' = f'g + fg'"),
                Passo(falado="A derivada de x ao quadrado é dois x. A derivada de seno de x é cosseno de x.",
                      latex="(x^2)' = 2x,\\ (\\sin x)' = \\cos x"),
            ],
            resposta_falada=(
                "A resposta final é dois x seno de x." if wrong else
                "A resposta final é dois x seno de x, mais x ao quadrado vezes cosseno de x."
            ),
            resposta_latex="2x\\sin x" if wrong else "2x\\sin x + x^2\\cos x",
        )


def get_provider(settings: Settings) -> LLMProvider:
    if settings.llm_provider == "fake":
        return FakeProvider()
    if settings.llm_provider == "gemini":
        return GeminiProvider(settings.gemini_api_key, settings.gemini_model)
    raise LLMError(f"LLM_PROVIDER desconhecido: {settings.llm_provider}", retryable=False)
