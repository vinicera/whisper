"""Converte uma expressao SymPy em portugues falado, de forma deterministica.

Usado quando o resultado foi verificado pelo SymPy: a frase final ("A resposta
final e ...") pode ser gerada daqui, sem depender do texto do modelo.
"""
from __future__ import annotations

import re

import sympy as sp

_SMALL = [
    "zero", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez",
    "onze", "doze", "treze", "quatorze", "quinze", "dezesseis", "dezessete", "dezoito",
    "dezenove", "vinte",
]
_DENOM = {2: ("meio", "meios"), 3: ("terço", "terços"), 4: ("quarto", "quartos"),
          5: ("quinto", "quintos"), 6: ("sexto", "sextos"), 7: ("sétimo", "sétimos"),
          8: ("oitavo", "oitavos"), 9: ("nono", "nonos"), 10: ("décimo", "décimos")}
_GREEK = {"theta": "teta", "alpha": "alfa", "beta": "beta", "gamma": "gama", "lambda": "lâmbda",
          "mu": "mi", "phi": "fi", "omega": "ômega", "epsilon": "épsilon", "delta": "delta",
          "sigma": "sigma", "rho": "rô", "tau": "tau"}
_FUNCS = {
    sp.sin: "seno", sp.cos: "cosseno", sp.tan: "tangente", sp.cot: "cotangente",
    sp.sec: "secante", sp.csc: "cossecante", sp.asin: "arco seno", sp.acos: "arco cosseno",
    sp.atan: "arco tangente", sp.sinh: "seno hiperbólico", sp.cosh: "cosseno hiperbólico",
    sp.tanh: "tangente hiperbólica", sp.log: "logaritmo natural",
}


def _number(n: int) -> str:
    if n < 0:
        return "menos " + _number(-n)
    return _SMALL[n] if n <= 20 else str(n)


def _rational(r: sp.Rational) -> str:
    p, q = int(r.p), int(r.q)
    if q == 1:
        return _number(p)
    sign = "menos " if p < 0 else ""
    p = abs(p)
    if q in _DENOM and p <= 20:
        word = _DENOM[q][0] if p == 1 else _DENOM[q][1]
        return f"{sign}{_number(p)} {word}"
    return f"{sign}{_number(p)} sobre {_number(q)}"


def _is_atom(e: sp.Basic) -> bool:
    return bool(
        e.is_Symbol
        or (e.is_Integer and e >= 0)
        or e in (sp.pi, sp.E, sp.oo)
    )


def _is_simple(e: sp.Basic) -> bool:
    """Pode ser justaposto sem 'vezes' (x, 2, x ao quadrado...)."""
    if _is_atom(e):
        return True
    if e.is_Pow:
        b, x = e.as_base_exp()
        return _is_atom(b) and x.is_Integer and x > 0
    return False


def _is_simple_product(e: sp.Basic) -> bool:
    """2x, 3x ao quadrado, x y: produto curto que dispensa 'a quantidade'."""
    if not e.is_Mul or e.could_extract_minus_sign():
        return False
    coeff, rest = e.as_coeff_Mul()
    return (coeff.is_Integer and coeff > 0) and all(_is_simple(f) for f in sp.Mul.make_args(rest))


def _group(e: sp.Basic) -> str:
    if e.is_Add:
        return f"a quantidade {_speak(e)},"
    if e.is_Mul and not _is_simple(e) and not _is_simple_product(e):
        return f"a quantidade {_speak(e)},"
    return _speak(e)


def _frac(num: sp.Basic, den: sp.Basic) -> str:
    if _is_simple(num) and _is_simple(den):
        return f"{_speak(num)} sobre {_speak(den)}"
    return f"a fração com numerador {_speak(num)}, e denominador {_speak(den)},"


def _func_arg(e: sp.Basic) -> str:
    return _speak(e) if _is_simple(e) else f"{_speak(e)},"


def _speak(e: sp.Basic) -> str:  # noqa: C901 - um despachante por tipo e mais legivel assim
    if e is sp.oo:
        return "infinito"
    if e is -sp.oo:
        return "menos infinito"
    if e is sp.zoo:
        return "infinito complexo"
    if e is sp.pi:
        return "pi"
    if e is sp.E:
        return "e"
    if e is sp.I:
        return "i"
    if e is sp.nan:
        return "indefinido"
    if e.is_Integer:
        return _number(int(e))
    if e.is_Rational:
        return _rational(e)
    if e.is_Float:
        v = float(e)
        txt = f"{abs(v):.6g}".replace(".", ",")
        return ("menos " if v < 0 else "") + txt
    if e.is_Symbol:
        name = e.name
        return _GREEK.get(name, name)

    if isinstance(e, sp.Eq):
        return f"{_speak(e.lhs)} igual a {_speak(e.rhs)}"

    if e.is_Add:
        terms = e.as_ordered_terms()
        out = _speak(terms[0])
        for t in terms[1:]:
            if t.could_extract_minus_sign():
                out += " menos " + _speak(-t)
            else:
                out += " mais " + _speak(t)
        return out

    if e.is_Mul:
        if e.could_extract_minus_sign():
            return "menos " + _speak(-e)
        num, den = sp.fraction(e)
        if den != 1:
            return _frac(num, den)
        coeff, rest = e.as_coeff_Mul()
        factors = sp.Mul.make_args(rest)
        all_simple = all(_is_simple(f) for f in factors)
        body = (" " if all_simple else " vezes ").join(_group(f) for f in factors)
        if coeff == 1:
            return body
        if coeff.is_Rational and not coeff.is_Integer:
            return f"{_rational(coeff)} de {body}"
        sep = " " if _is_simple(factors[0]) else " vezes "
        return f"{_speak(coeff)}{sep}{body}"

    if isinstance(e, sp.exp):
        return f"e elevado a {_group(e.args[0])}"

    if e.is_Pow:
        b, x = e.as_base_exp()
        if b is sp.E:
            return f"e elevado a {_group(x)}"
        if x.is_negative:
            return _frac(sp.Integer(1), b ** (-x))
        if x == sp.Rational(1, 2):
            return f"raiz quadrada de {_func_arg(b)}"
        if x == sp.Rational(1, 3):
            return f"raiz cúbica de {_func_arg(b)}"
        if x == 2:
            return f"{_group(b)} ao quadrado"
        if x == 3:
            return f"{_group(b)} ao cubo"
        return f"{_group(b)} elevado a {_group(x)}"

    if isinstance(e, sp.Abs):
        return f"módulo de {_func_arg(e.args[0])}"

    for cls, name in _FUNCS.items():
        if isinstance(e, cls):
            return f"{name} de {_func_arg(e.args[0])}"

    if isinstance(e, sp.Derivative):
        var = e.variables[0]
        order = len(e.variables)
        ordem = "" if order == 1 else ("segunda " if order == 2 else f"derivada de ordem {order}, ")
        return f"a {ordem}derivada em relação a {_speak(var)} de {_speak(e.expr)}"

    if isinstance(e, sp.Integral):
        lim = e.limits[0]
        var = _speak(lim[0])
        if len(lim) == 3:
            return (f"a integral de {_speak(lim[1])} até {_speak(lim[2])} de "
                    f"{_speak(e.function)}, em relação a {var}")
        return f"a integral de {_speak(e.function)}, em relação a {var}"

    if isinstance(e, sp.Limit):
        expr, z, z0 = e.args[0], e.args[1], e.args[2]
        lado = " pela esquerda" if str(e.args[3]) == "-" else ""
        return f"o limite quando {_speak(z)} tende a {_speak(z0)}{lado}, de {_speak(expr)}"

    # Fallback: texto do SymPy passado pelo sanitizador.
    from .sanitizer import sanitize_for_speech

    return sanitize_for_speech(str(e))


def to_speech(expr: sp.Basic) -> str:
    text = _speak(sp.sympify(expr))
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r",(\s*,)+", ",", text)
    text = re.sub(r",\s*(mais|menos|vezes|sobre|e denominador)\b", r", \1", text)
    return text.strip(" ,")
