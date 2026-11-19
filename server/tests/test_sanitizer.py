import json

import pytest

from app.sanitizer import find_forbidden, sanitize_for_speech
from conftest import REPO_DIR

CASES = json.loads((REPO_DIR / "shared" / "contract" / "sanitizer_cases.json").read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", CASES, ids=[c["input"] for c in CASES])
def test_shared_cases(case):
    out = sanitize_for_speech(case["input"])
    assert find_forbidden(out) == [], out
    for piece in case["must_contain"]:
        assert piece in out, f"{piece!r} ausente em {out!r}"


def test_plain_text_untouched():
    text = "A resposta final é dois x seno de x, mais x ao quadrado vezes cosseno de x."
    assert sanitize_for_speech(text) == text


def test_hyphenated_words_kept():
    assert "passo-a-passo" in sanitize_for_speech("Vamos passo-a-passo.")


def test_find_forbidden_detects():
    assert "^" in find_forbidden("x^2")
    assert "-" in find_forbidden("x - 1")
    assert find_forbidden("x ao quadrado menos um") == []
