import Foundation

// Saida estruturada do modelo (espelho de ModelAnswer em server/app/models.py).
// Usada no Modo Direto, quando o app fala com o Gemini sem passar pelo PC.

public struct SympyCheck: Codable, Sendable {
    public var expr: String?
    public var `var`: String?
    public var operacao: String?
    public var ordem: Int?
    public var inferior: String?
    public var superior: String?
    public var tendeA: String?
    public var lado: String?
    public var resultado: String?
}

public struct Passo: Codable, Sendable {
    public var falado: String?
    public var latex: String?

    public init(falado: String?, latex: String? = nil) {
        self.falado = falado
        self.latex = latex
    }
}

public struct ModelAnswer: Codable, Sendable {
    public var legivel: Bool
    public var motivoIlegivelFalado: String?
    /// Rotulos falados de todas as questoes da folha, na ordem de leitura.
    public var questoesNaFolha: [String]?
    /// Posicao (1 = primeira) da questao resolvida.
    public var questaoAtual: Int?
    public var questaoFalada: String?
    public var enunciadoLatex: String?
    public var enunciadoFalado: String?
    public var tipo: String?
    public var planoFalado: String?
    public var sympy: SympyCheck?
    public var passos: [Passo]?
    public var respostaFalada: String?
    public var respostaLatex: String?

    public init(legivel: Bool, motivoIlegivelFalado: String? = nil, enunciadoFalado: String? = nil,
                planoFalado: String? = nil, passos: [Passo]? = nil, respostaFalada: String? = nil) {
        self.legivel = legivel
        self.motivoIlegivelFalado = motivoIlegivelFalado
        self.enunciadoFalado = enunciadoFalado
        self.planoFalado = planoFalado
        self.passos = passos
        self.respostaFalada = respostaFalada
    }
}

/// Monta os segmentos falados a partir da resposta do modelo
/// (mesma regra de build_segments em server/app/solve.py, sem o SymPy).
public enum SegmentBuilder {
    public static func segments(from a: ModelAnswer, mode: SolveMode) -> [SpeechSegment] {
        var raw: [(String, String)] = []
        if let q = a.questaoFalada { raw.append(("questao", q)) }
        if let e = a.enunciadoFalado { raw.append(("enunciado", e)) }
        if mode != .ditado {
            if mode == .tutor, let p = a.planoFalado { raw.append(("plano", p)) }
            let passos = a.passos ?? []
            for p in (mode == .tutor ? passos : Array(passos.prefix(2))) {
                if let f = p.falado { raw.append(("passo", f)) }
            }
            let r = a.respostaFalada ?? ""
            raw.append(("resposta", r.isEmpty ? "Não consegui formular a resposta final." : r))
        }
        var out: [SpeechSegment] = []
        for (kind, text) in raw {
            let clean = SpeechSanitizer.sanitize(text)
            if !clean.isEmpty { out.append(SpeechSegment(id: out.count + 1, kind: kind, text: clean)) }
        }
        return out
    }

    public static func response(from a: ModelAnswer, mode: SolveMode,
                                requestId: String = UUID().uuidString) -> SolveResponse {
        guard a.legivel else {
            let text = SpeechSanitizer.sanitize(a.motivoIlegivelFalado ?? "")
            let spoken = text.isEmpty ? "Não consegui ler a questão. Tente fotografar mais perto e com mais luz." : text
            return SolveResponse(
                requestId: requestId, status: .unreadable,
                speech: Speech(fullText: spoken, segments: [SpeechSegment(id: 1, kind: "aviso", text: spoken)]),
                verification: Verification(performed: false, notes: "imagem ilegível"),
                error: ErrorInfo(code: "IMAGE_UNREADABLE", retryable: true))
        }
        let segs = segments(from: a, mode: mode)
        let full = segs.map(\.text).joined(separator: " ")
        var response = SolveResponse(
            requestId: requestId, status: .ok,
            speech: Speech(fullText: full, segments: segs),
            verification: Verification(performed: false, notes: "Modo Direto: sem verificação SymPy"))
        let labels = a.questoesNaFolha ?? []
        if !labels.isEmpty {
            response.questoes = labels
            response.questaoAtual = a.questaoAtual ?? 1
        }
        return response
    }
}
