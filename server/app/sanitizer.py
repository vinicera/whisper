"""Ultima barreira: transforma qualquer resto de LaTeX/simbolo em fala pt-BR.

O prompt ja proibe simbolos; isto garante que o TTS nunca leia "circunflexo",
"barra invertida" etc. A mesma logica existe em Swift (Core/SpeechSanitizer.swift)
e ambos sao testados contra shared/contract/sanitizer_cases.json.
"""
from __future__ import annotations

import re

# Caracteres que nunca podem chegar ao TTS.
FORBIDDEN_CHARS = set("^_\\{}$*/=+−±·×÷√∛∫∑∏∞πθαβΔ≤≥≠≈→'|()[]#`<>²³⁴⁵⁶⁷⁸⁹ⁿ")
# Hifen e permitido so dentro de palavras (passo-a-passo); fora disso e "menos".
_MINUS_RE = re.compile(r"(?<![A-Za-zÀ-ÿ])-|-(?![A-Za-zÀ-ÿ])")

_LATEX_WORDS = {
    "arcsin": " arco seno de ", "arccos": " arco cosseno de ", "arctan": " arco tangente de ",
    "sinh": " seno hiperbólico de ", "cosh": " cosseno hiperbólico de ", "tanh": " tangente hiperbólica de ",
    "sin": " seno de ", "sen": " seno de ", "cos": " cosseno de ", "tan": " tangente de ", "tg": " tangente de ",
    "cot": " cotangente de ", "sec": " secante de ", "csc": " cossecante de ",
    "ln": " logaritmo natural de ", "log": " logaritmo de ", "exp": " exponencial de ",
    "infty": " infinito ", "pi": " pi ", "theta": " teta ", "alpha": " alfa ", "beta": " beta ",
    "gamma": " gama ", "lambda": " lâmbda ", "Delta": " delta ", "delta": " delta ",
    "epsilon": " épsilon ", "varepsilon": " épsilon ", "phi": " fi ", "omega": " ômega ",
    "cdot": " vezes ", "times": " vezes ", "div": " dividido por ", "pm": " mais ou menos ",
    "leq": " menor ou igual a ", "le": " menor ou igual a ", "geq": " maior ou igual a ",
    "ge": " maior ou igual a ", "neq": " diferente de ", "approx": " aproximadamente ",
    "to": " tende a ", "rightarrow": " tende a ", "infin": " infinito ",
    "int": " integral de ", "iint": " integral dupla de ", "sum": " somatório de ",
    "lim": " limite de ", "partial": " derivada parcial ",
}

_SUPERSCRIPTS = {"²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "ⁿ": "n"}

_SYMBOLS = [
    ("≤", " menor ou igual a "), ("≥", " maior ou igual a "), ("≠", " diferente de "),
    ("≈", " aproximadamente "), ("→", " tende a "), ("±", " mais ou menos "),
    ("∛", " raiz cúbica de "), ("√", " raiz quadrada de "), ("∫", " integral de "),
    ("∑", " somatório de "), ("∏", " produtório de "), ("∞", " infinito "), ("π", " pi "),
    ("θ", " teta "), ("α", " alfa "), ("β", " beta "), ("Δ", " delta "),
    ("·", " vezes "), ("×", " vezes "), ("*", " vezes "), ("÷", " dividido por "),
    ("/", " sobre "), ("=", " igual a "), ("+", " mais "), ("−", " menos "),
    ("<", " menor que "), (">", " maior que "),
]


def _power_words(exp: str) -> str:
    exp = exp.strip()
    if exp == "2":
        return " ao quadrado "
    if exp == "3":
        return " ao cubo "
    return f" elevado a {exp} "


def sanitize_for_speech(text: str) -> str:
    if not text:
        return ""
    s = text

    # 1. Markdown (antes de '*' virar "vezes").
    s = re.sub(r"```.*?```", " ", s, flags=re.S)
    s = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s+", "", s, flags=re.M)
    s = re.sub(r"\*\*|__|`|^#+\s*", "", s, flags=re.M)
    s = s.replace("$", " ")

    # 2. Estruturas LaTeX (de dentro para fora, ate estabilizar).
    s = re.sub(r"\\(?:left|right|displaystyle|,|;|!|quad|qquad)", " ", s)
    s = re.sub(r"\\(?:mathrm|text|operatorname|mathbf|mathit)\{([^{}]*)\}", r" \1 ", s)
    for _ in range(6):
        before = s
        s = re.sub(r"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}", r" \1 sobre \2 ", s)
        s = re.sub(r"\\sqrt\[3\]\{([^{}]*)\}", r" raiz cúbica de \1 ", s)
        s = re.sub(r"\\sqrt\[([^\]]*)\]\{([^{}]*)\}", r" raiz de índice \1 de \2 ", s)
        s = re.sub(r"\\sqrt\{([^{}]*)\}", r" raiz quadrada de \1 ", s)
        if s == before:
            break
    s = re.sub(r"\\lim_\{([^{}]*)\}", r" o limite quando \1, de ", s)
    s = re.sub(r"\\int_\{?([^{}\s^]+)\}?\^\{?([^{}\s]+)\}?", r" a integral de \1 até \2 de ", s)
    s = re.sub(r"\\sum_\{([^{}]*)\}\^\{?([^{}\s]+)\}?", r" o somatório de \1 até \2 de ", s)
    for word in sorted(_LATEX_WORDS, key=len, reverse=True):
        s = re.sub(r"\\" + word + r"(?![A-Za-z])", _LATEX_WORDS[word], s)
    s = re.sub(r"\\[A-Za-z]+", " ", s)
    s = s.replace("\\", " ")
    # Funcoes em texto puro, so quando seguidas de parenteses: sin(x), sqrt(x+1).
    s = re.sub(r"\bsqrt\s*\(", " raiz quadrada de (", s)
    s = re.sub(r"\b(arcsin|arccos|arctan|sinh|cosh|tanh|sin|sen|cos|tan|tg|cot|sec|csc|ln|log|exp)\s*\(",
               lambda m: _LATEX_WORDS[m.group(1)] + "(", s)

    # 3. Potencias e indices.
    for sup, digit in _SUPERSCRIPTS.items():
        s = s.replace(sup, "^{" + digit + "}")
    s = re.sub(r"\^\s*\{([^{}]*)\}", lambda m: _power_words(m.group(1)), s)
    s = re.sub(r"\^\s*\(([^()]*)\)", lambda m: _power_words(m.group(1)), s)
    s = re.sub(r"\^\s*(-?\d+|-?[A-Za-z])", lambda m: _power_words(m.group(1)), s)
    s = s.replace("^", " elevado a ")
    s = re.sub(r"_\{([^{}]*)\}", r" índice \1 ", s)
    s = re.sub(r"_(\w)", r" índice \1 ", s)
    s = s.replace("_", " ")
    s = s.replace("{", " ").replace("}", " ")

    # 4. Derivadas (linha), modulo, decimais.
    s = re.sub(r"(\w)''", r"\1 duas linhas", s)
    s = re.sub(r"(\w)'", r"\1 linha", s)
    s = s.replace("'", " ")
    s = re.sub(r"\|([^|]+)\|", r" módulo de \1 ", s)
    s = s.replace("|", " ")
    s = re.sub(r"(\d)\.(\d)", r"\1,\2", s)

    # 5. Operadores e simbolos restantes.
    for sym, words in _SYMBOLS:
        s = s.replace(sym, words)
    s = _MINUS_RE.sub(" menos ", s)
    s = re.sub(r"[()\[\]]", " ", s)
    s = s.replace("#", " ")

    # 6. Limpeza de espacos e pontuacao.
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\s+([,.;:!?])", r"\1", s)
    s = re.sub(r"([,;])(\s*[,;])+", r"\1", s)
    s = re.sub(r"\n{2,}", "\n", s)
    return s.strip(" ,;\n")


def find_forbidden(text: str) -> list[str]:
    """Simbolos proibidos que restaram no texto (vazio = seguro para o TTS)."""
    found = {c for c in text if c in FORBIDDEN_CHARS}
    if _MINUS_RE.search(text):
        found.add("-")
    return sorted(found)
