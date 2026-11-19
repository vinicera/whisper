import pytest

from app.verify_sympy import UnsafeExpression, _check_text, verify


def block(**kw):
    base = {"var": "x", "ordem": None, "inferior": None, "superior": None, "tende_a": None, "lado": None}
    base.update(kw)
    return base


@pytest.mark.parametrize(
    "b, passed",
    [
        (block(expr="x**2*sin(x)", operacao="derivar", resultado="2*x*sin(x) + x**2*cos(x)"), True),
        (block(expr="x**2*sin(x)", operacao="derivar", resultado="2*x*sin(x)"), False),
        (block(expr="x**3", operacao="derivar", ordem=2, resultado="6*x"), True),
        (block(expr="2*x*cos(x**2)", operacao="integrar_indefinida", resultado="sin(x**2) + C"), True),
        (block(expr="1/x", operacao="integrar_indefinida", resultado="ln(Abs(x)) + C"), True),
        (block(expr="x**2", operacao="integrar_definida", inferior="0", superior="1", resultado="1/3"), True),
        (block(expr="sin(x)/x", operacao="limite", tende_a="0", resultado="1"), True),
        (block(expr="(1 + 1/x)**x", operacao="limite", tende_a="oo", resultado="E"), True),
        (block(expr="x**2 - 5*x + 6", operacao="resolver", resultado="2; 3"), True),
        (block(expr="x**2 - 5*x + 6", operacao="resolver", resultado="2"), False),
        (block(expr="(x**2 - 1)/(x - 1)", operacao="simplificar", resultado="x + 1"), True),
        (block(expr="x^2", operacao="derivar", resultado="2x"), True),  # sintaxe "humana"
    ],
)
def test_verify(b, passed):
    r = verify(b, timeout=30)
    assert r.performed, r.notes
    assert r.passed is passed, r.notes


@pytest.mark.parametrize(
    "s",
    ["__import__('os').system('calc')", "open('x')", "x; import os", "eval(x)", "1234567890**2", "lambda: 1"],
)
def test_unsafe_rejected(s):
    with pytest.raises(UnsafeExpression):
        _check_text(s)


def test_unsafe_reports_not_performed():
    r = verify(block(expr="__import__('os')", operacao="derivar", resultado="0"), timeout=30)
    assert r.performed is False


def test_timeout_kills_worker_and_recovers():
    r = verify(block(expr="9**9**9**9", operacao="simplificar", resultado="1"), timeout=2)
    assert r.performed is False
    # O pool foi recriado e volta a funcionar.
    ok = verify(block(expr="x**2", operacao="derivar", resultado="2*x"), timeout=60)
    assert ok.passed is True


def test_nenhuma():
    assert verify(block(expr="x", operacao="nenhuma", resultado="x"), timeout=30).performed is False
