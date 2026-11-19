import pytest
import sympy as sp

from app.sanitizer import find_forbidden
from app.spoken_math import to_speech

x, t = sp.symbols("x t")


@pytest.mark.parametrize(
    "expr, expected",
    [
        (x**2, "x ao quadrado"),
        (x**3, "x ao cubo"),
        (x**5, "x elevado a cinco"),
        (2 * x, "dois x"),
        (sp.Rational(2, 3), "dois terços"),
        (sp.Rational(1, 2), "um meio"),
        (-3, "menos três"),
        (sp.sqrt(x), "raiz quadrada de x"),
        (sp.sin(x), "seno de x"),
        (sp.exp(2 * x), "e elevado a dois x"),
        (sp.log(x), "logaritmo natural de x"),
        (1 / x, "um sobre x"),
        (sp.oo, "infinito"),
        (sp.pi / 4, "pi sobre quatro"),
        (x**3 / 3, "x ao cubo sobre três"),
    ],
)
def test_basic(expr, expected):
    assert to_speech(expr) == expected


def test_product_rule_result():
    out = to_speech(2 * x * sp.sin(x) + x**2 * sp.cos(x))
    assert "dois x vezes seno de x" in out
    assert "x ao quadrado vezes cosseno de x" in out
    assert " mais " in out


def test_subtraction_and_fraction():
    out = to_speech((x + 1) / (x - 1))
    assert out.startswith("a fração com numerador x mais um")
    assert "denominador x menos um" in out


def test_no_symbols_ever():
    exprs = [
        sp.Integral(x**2, (x, 0, 1)),
        sp.Derivative(sp.sin(t), t),
        sp.Limit(sp.sin(x) / x, x, 0),
        sp.Abs(x - 2),
        (x + 1) ** 2,
        sp.Float(0.25),
    ]
    for e in exprs:
        out = to_speech(e)
        assert find_forbidden(out) == [], (e, out)
