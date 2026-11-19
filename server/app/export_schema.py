"""Gera shared/contract/*.schema.json a partir de app/models.py.

Uso (na pasta server/):  python -m app.export_schema
O teste tests/test_contract.py falha se os arquivos estiverem desatualizados.
"""
from __future__ import annotations

import json
from pathlib import Path

from .models import ModelAnswer, SolveRequest, SolveResponse

CONTRACT_DIR = Path(__file__).resolve().parents[2] / "shared" / "contract"
SCHEMAS = {
    "solve_request.schema.json": SolveRequest,
    "solve_response.schema.json": SolveResponse,
    "model_answer.schema.json": ModelAnswer,
}


def render(model) -> str:
    return json.dumps(model.model_json_schema(), ensure_ascii=False, indent=2) + "\n"


def main() -> None:
    CONTRACT_DIR.mkdir(parents=True, exist_ok=True)
    for name, model in SCHEMAS.items():
        (CONTRACT_DIR / name).write_text(render(model), encoding="utf-8")
        print("escrito", CONTRACT_DIR / name)


if __name__ == "__main__":
    main()
