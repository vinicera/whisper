import Foundation

/// Ultima barreira antes do TTS. Porta de server/app/sanitizer.py;
/// ambos sao testados contra shared/contract/sanitizer_cases.json.
public enum SpeechSanitizer {
    public static let forbiddenCharacters: Set<Character> = Set("^_\\{}$*/=+−±·×÷√∛∫∑∏∞πθαβΔ≤≥≠≈→'|()[]#`<>²³⁴⁵⁶⁷⁸⁹ⁿ")

    private static let minusPattern = #"(?<![A-Za-zÀ-ÿ])-|-(?![A-Za-zÀ-ÿ])"#

    private static let latexWords: [String: String] = [
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
    ]

    private static let superscripts: [(String, String)] = [
        ("²", "2"), ("³", "3"), ("⁴", "4"), ("⁵", "5"), ("⁶", "6"),
        ("⁷", "7"), ("⁸", "8"), ("⁹", "9"), ("ⁿ", "n"),
    ]

    private static let symbols: [(String, String)] = [
        ("≤", " menor ou igual a "), ("≥", " maior ou igual a "), ("≠", " diferente de "),
        ("≈", " aproximadamente "), ("→", " tende a "), ("±", " mais ou menos "),
        ("∛", " raiz cúbica de "), ("√", " raiz quadrada de "), ("∫", " integral de "),
        ("∑", " somatório de "), ("∏", " produtório de "), ("∞", " infinito "), ("π", " pi "),
        ("θ", " teta "), ("α", " alfa "), ("β", " beta "), ("Δ", " delta "),
        ("·", " vezes "), ("×", " vezes "), ("*", " vezes "), ("÷", " dividido por "),
        ("/", " sobre "), ("=", " igual a "), ("+", " mais "), ("−", " menos "),
        ("<", " menor que "), (">", " maior que "),
    ]

    private static func powerWords(_ exp: String) -> String {
        let e = exp.trimmingCharacters(in: .whitespaces)
        if e == "2" { return " ao quadrado " }
        if e == "3" { return " ao cubo " }
        return " elevado a \(e) "
    }

    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = text

        // 1. Markdown (antes de '*' virar "vezes").
        s = sub(s, #"```.*?```"#, options: [.dotMatchesLineSeparators]) { _ in " " }
        s = sub(s, #"^\s*(?:[-*•]|\d+[.)])\s+"#, options: [.anchorsMatchLines]) { _ in "" }
        s = sub(s, #"\*\*|__|`|^#+\s*"#, options: [.anchorsMatchLines]) { _ in "" }
        s = s.replacingOccurrences(of: "$", with: " ")

        // 2. Estruturas LaTeX.
        s = sub(s, #"\\(?:left|right|displaystyle|,|;|!|quad|qquad)"#) { _ in " " }
        s = sub(s, #"\\(?:mathrm|text|operatorname|mathbf|mathit)\{([^{}]*)\}"#) { " \($0[1]) " }
        for _ in 0..<6 {
            let before = s
            s = sub(s, #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#) { " \($0[1]) sobre \($0[2]) " }
            s = sub(s, #"\\sqrt\[3\]\{([^{}]*)\}"#) { " raiz cúbica de \($0[1]) " }
            s = sub(s, #"\\sqrt\[([^\]]*)\]\{([^{}]*)\}"#) { " raiz de índice \($0[1]) de \($0[2]) " }
            s = sub(s, #"\\sqrt\{([^{}]*)\}"#) { " raiz quadrada de \($0[1]) " }
            if s == before { break }
        }
        s = sub(s, #"\\lim_\{([^{}]*)\}"#) { " o limite quando \($0[1]), de " }
        s = sub(s, #"\\int_\{?([^{}\s^]+)\}?\^\{?([^{}\s]+)\}?"#) { " a integral de \($0[1]) até \($0[2]) de " }
        s = sub(s, #"\\sum_\{([^{}]*)\}\^\{?([^{}\s]+)\}?"#) { " o somatório de \($0[1]) até \($0[2]) de " }
        for word in latexWords.keys.sorted(by: { $0.count > $1.count }) {
            let words = latexWords[word]!
            s = sub(s, #"\\"# + word + #"(?![A-Za-z])"#) { _ in words }
        }
        s = sub(s, #"\\[A-Za-z]+"#) { _ in " " }
        s = s.replacingOccurrences(of: "\\", with: " ")
        s = sub(s, #"\bsqrt\s*\("#) { _ in " raiz quadrada de (" }
        s = sub(s, #"\b(arcsin|arccos|arctan|sinh|cosh|tanh|sin|sen|cos|tan|tg|cot|sec|csc|ln|log|exp)\s*\("#) {
            (latexWords[$0[1]] ?? " ") + "("
        }

        // 3. Potencias e indices.
        for (sup, digit) in superscripts {
            s = s.replacingOccurrences(of: sup, with: "^{\(digit)}")
        }
        s = sub(s, #"\^\s*\{([^{}]*)\}"#) { powerWords($0[1]) }
        s = sub(s, #"\^\s*\(([^()]*)\)"#) { powerWords($0[1]) }
        s = sub(s, #"\^\s*(-?\d+|-?[A-Za-z])"#) { powerWords($0[1]) }
        s = s.replacingOccurrences(of: "^", with: " elevado a ")
        s = sub(s, #"_\{([^{}]*)\}"#) { " índice \($0[1]) " }
        s = sub(s, #"_(\w)"#) { " índice \($0[1]) " }
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")

        // 4. Linha (derivada), modulo, decimais.
        s = sub(s, #"(\w)''"#) { "\($0[1]) duas linhas" }
        s = sub(s, #"(\w)'"#) { "\($0[1]) linha" }
        s = s.replacingOccurrences(of: "'", with: " ")
        s = sub(s, #"\|([^|]+)\|"#) { " módulo de \($0[1]) " }
        s = s.replacingOccurrences(of: "|", with: " ")
        s = sub(s, #"(\d)\.(\d)"#) { "\($0[1]),\($0[2])" }

        // 5. Operadores restantes.
        for (sym, words) in symbols {
            s = s.replacingOccurrences(of: sym, with: words)
        }
        s = sub(s, minusPattern) { _ in " menos " }
        s = sub(s, #"[()\[\]]"#) { _ in " " }
        s = s.replacingOccurrences(of: "#", with: " ")

        // 6. Limpeza.
        s = sub(s, #"[ \t]+"#) { _ in " " }
        s = sub(s, #"\s+([,.;:!?])"#) { $0[1] }
        s = sub(s, #"([,;])(\s*[,;])+"#) { $0[1] }
        s = sub(s, #"\n{2,}"#) { _ in "\n" }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;\n"))
    }

    /// Simbolos proibidos que restaram (vazio = seguro para o TTS).
    public static func forbidden(in text: String) -> [String] {
        var found = Set(text.filter { forbiddenCharacters.contains($0) }.map(String.init))
        if !matches(text, minusPattern).isEmpty { found.insert("-") }
        return found.sorted()
    }

    // MARK: - Regex helpers (NSRegularExpression: funciona em iOS, macOS e Linux)

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let r = cache[key] { return r }
        // Padroes sao constantes do codigo: falhar aqui e bug de programacao.
        let r = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = r
        return r
    }

    private static func matches(_ s: String, _ pattern: String,
                                options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        regex(pattern, options).matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Substitui cada ocorrencia por `transform(grupos)`, onde grupos[0] e o match inteiro.
    private static func sub(_ s: String, _ pattern: String, options: NSRegularExpression.Options = [],
                            _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in matches(s, pattern, options: options) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
