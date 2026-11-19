"""Verificacao matematica com SymPy, isolada em processo separado.

Seguranca: as expressoes vem do modelo, que leu uma imagem (logo podem ser
influenciadas por texto na foto). `parse_expr` usa eval, entao so aceitamos um
alfabeto restrito e uma lista fechada de nomes. Alem disso, tudo roda num
processo filho com timeout, que e morto se travar (ex.: 9**9**9**9).
"""
from __future__ import annotations

import math
import multiprocessing as mp
import re
import threading
from dataclasses import dataclass
from typing import Optional

_SAFE_CHARS = re.compile(r"^[0-9A-Za-z_+\-*/^().\s]*$")
_TOKEN = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_ALLOWED_NAMES = {
    "sin", "cos", "tan", "cot", "sec", "csc", "asin", "acos", "atan", "arcsin", "arccos", "arctan",
    "sinh", "cosh", "tanh", "exp", "log", "ln", "sqrt", "Abs", "abs", "pi", "E", "oo", "inf",
    "theta", "alpha", "beta", "gamma", "mu", "phi", "omega", "epsilon", "delta", "tau",
}
_MAX_LEN = 400
_MAX_DIGITS = 6


class UnsafeExpression(ValueError):
    pass


@dataclass
class VerifyResult:
    performed: bool
    passed: Optional[bool] = None
    notes: Optional[str] = None
    canonical: Optional[str] = None  # resultado calculado pelo SymPy (str sympy)


# --------------------------------------------------------------------------
# Execucao no processo filho
# --------------------------------------------------------------------------

def _check_text(s: str) -> str:
    s = (s or "").strip()
    if not s or len(s) > _MAX_LEN or "__" in s or not _SAFE_CHARS.match(s):
        raise UnsafeExpression(f"expressao recusada: {s[:60]!r}")
    for tok in _TOKEN.findall(s):
        if len(tok) > 1 and tok not in _ALLOWED_NAMES:
            raise UnsafeExpression(f"nome nao permitido: {tok}")
    if re.search(r"\d{%d,}" % (_MAX_DIGITS + 1), s):
        raise UnsafeExpression("numero grande demais")
    return s


def _parse(s: str, evaluate: bool = True):
    """Parse com lista branca. Fora do processo filho, use evaluate=False
    (nao calcula nada, entao nao trava com torres de potencias)."""
    import sympy as sp
    from sympy.parsing.sympy_parser import (
        convert_xor, implicit_application, implicit_multiplication, parse_expr,
        standard_transformations,
    )

    s = _check_text(s)
    local = {
        "ln": sp.log, "log": sp.log, "arcsin": sp.asin, "arccos": sp.acos, "arctan": sp.atan,
        "abs": sp.Abs, "Abs": sp.Abs, "e": sp.E, "E": sp.E, "inf": sp.oo, "oo": sp.oo, "pi": sp.pi,
    }
    for letter in "abcdfghijklmnopqrstuvwxyzABCDFGHIJKLMNOPQRSTUVWXYZ":
        local.setdefault(letter, sp.Symbol(letter, real=True))
    transformations = standard_transformations + (
        implicit_multiplication, implicit_application, convert_xor,
    )
    return parse_expr(s, local_dict=local, transformations=transformations, evaluate=evaluate)


def parse_safe_unevaluated(s: str):
    return _parse(s, evaluate=False)


_SAMPLE_POINTS = [0.37, 1.13, 2.71, 0.61, 3.3, 1.9]


def _numerically_equal(a, b) -> Optional[bool]:
    import sympy as sp

    diff = a - b
    syms = sorted(diff.free_symbols, key=lambda s: s.name)
    if not syms:
        try:
            v = complex(sp.N(diff, 30))
            return abs(v) < 1e-9 * (1 + abs(complex(sp.N(a, 30))))
        except (TypeError, ValueError):
            return None
    valid = 0
    for i, p in enumerate(_SAMPLE_POINTS):
        subs = {s: p + 0.17 * k for k, s in enumerate(syms)}
        try:
            va = complex(sp.N(a.subs(subs), 20))
            vd = complex(sp.N(diff.subs(subs), 20))
        except (TypeError, ValueError, ZeroDivisionError):
            continue
        if any(math.isnan(x) or math.isinf(x) for x in (va.real, va.imag, vd.real, vd.imag)):
            continue
        valid += 1
        if abs(vd) > 1e-7 * (1 + abs(va)):
            return False
    return True if valid >= 3 else None


def _equal(a, b) -> Optional[bool]:
    import sympy as sp

    num = _numerically_equal(a, b)
    if num is not None:
        return num
    try:
        return sp.simplify(a - b) == 0
    except Exception:  # noqa: BLE001
        return None


def _run_check(block: dict) -> dict:
    """Roda no processo filho. Retorna dict serializavel."""
    import sympy as sp

    op = block.get("operacao", "nenhuma")
    if op == "nenhuma":
        return {"performed": False, "notes": "operação sem verificação automática"}
    try:
        var = sp.Symbol(block.get("var") or "x", real=True)
        if not re.fullmatch(r"[A-Za-z]", var.name) and var.name not in _ALLOWED_NAMES:
            raise UnsafeExpression("variável inválida")
        expr = _parse(block["expr"])

        if op == "resolver":
            roots = [_parse(r) for r in str(block["resultado"]).split(";") if r.strip()]
            if not roots:
                return {"performed": True, "passed": False, "notes": "nenhuma raiz informada"}
            bad = [str(r) for r in roots if _equal(expr.subs(var, r), sp.Integer(0)) is not True]
            expected = sp.solve(expr, var)
            canonical = "; ".join(str(r) for r in expected) if expected else None
            if bad:
                return {"performed": True, "passed": False, "canonical": canonical,
                        "notes": f"raízes que não satisfazem a equação: {bad}"}
            if expected and len(roots) < len(expected):
                return {"performed": True, "passed": False, "canonical": canonical,
                        "notes": f"faltam raízes; SymPy encontrou {expected}"}
            return {"performed": True, "passed": True, "canonical": canonical}

        result = _parse(block["resultado"])
        if op == "derivar":
            expected = sp.diff(expr, var, int(block.get("ordem") or 1))
            ok = _equal(result, expected)
        elif op == "integrar_indefinida":
            c = sp.Symbol("C", real=True)
            ok = _equal(sp.diff(result.subs(c, 0), var), expr)
            expected = None
        elif op == "integrar_definida":
            lo, hi = _parse(block["inferior"]), _parse(block["superior"])
            expected = sp.integrate(expr, (var, lo, hi))
            ok = _equal(result, expected)
        elif op == "limite":
            point = _parse(block["tende_a"])
            expected = sp.limit(expr, var, point, block.get("lado") or "+-")
            ok = _equal(result, expected) if expected.is_finite else (sp.simplify(result - expected) == 0 or result == expected)
        elif op == "simplificar":
            expected = None
            ok = _equal(result, expr)
        else:
            return {"performed": False, "notes": f"operação desconhecida: {op}"}

        out = {"performed": ok is not None, "passed": ok,
               "canonical": str(expected) if expected is not None else None}
        if ok is False:
            out["notes"] = f"divergência: modelo={result}, sympy={expected if expected is not None else 'derivada não confere'}"
        elif ok is None:
            out["notes"] = "não foi possível concluir a comparação"
        return out
    except UnsafeExpression as exc:
        return {"performed": False, "notes": str(exc)}
    except Exception as exc:  # noqa: BLE001 - qualquer falha de parse/calculo vira "nao verificado"
        return {"performed": False, "notes": f"erro no SymPy: {type(exc).__name__}: {exc}"[:300]}


# --------------------------------------------------------------------------
# Pool persistente (1 worker aquecido; recriado se estourar o timeout)
# --------------------------------------------------------------------------

_pool = None
_pool_lock = threading.Lock()


def _warmup() -> bool:
    import sympy  # noqa: F401

    return True


def _get_pool():
    global _pool
    with _pool_lock:
        if _pool is None:
            _pool = mp.get_context("spawn").Pool(processes=1)
        return _pool


def _reset_pool() -> None:
    global _pool
    with _pool_lock:
        if _pool is not None:
            _pool.terminate()
            _pool.join()
        _pool = None


def warmup(timeout: float = 60) -> None:
    _get_pool().apply_async(_warmup).get(timeout)


def shutdown() -> None:
    _reset_pool()


def verify(block: dict, timeout: float = 8.0) -> VerifyResult:
    try:
        res = _get_pool().apply_async(_run_check, (block,)).get(timeout)
    except mp.TimeoutError:
        _reset_pool()
        return VerifyResult(performed=False, notes=f"tempo esgotado ({timeout:.0f}s) no SymPy")
    return VerifyResult(
        performed=bool(res.get("performed")),
        passed=res.get("passed"),
        notes=res.get("notes"),
        canonical=res.get("canonical"),
    )
