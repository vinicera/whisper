import Foundation

/// Extrai, de um JSON do modelo que ainda esta chegando (streaming), os trechos
/// falados que ja terminaram, na ordem, para o app comecar a falar antes do fim.
///
/// Usa a ordem garantida pelo esquema (propertyOrdering): enunciado_falado,
/// plano_falado, passos[].falado, resposta_falada. Aplica as mesmas regras de
/// modo do `SegmentBuilder`, entao a soma dos trechos emitidos e igual ao que
/// `SegmentBuilder.segments` produziria com o JSON completo.
public struct StreamingSegmentExtractor {
    public let mode: SolveMode
    /// true quando o modelo declarou a imagem ilegivel (nada e emitido).
    public private(set) var unreadable = false

    private var rawEmitted = 0
    private var segmentCount = 0

    private static let fieldRegex = try! NSRegularExpression(
        pattern: #""(questao_falada|enunciado_falado|plano_falado|falado|resposta_falada)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
    private static let unreadableRegex = try! NSRegularExpression(pattern: #""legivel"\s*:\s*false"#)

    public init(mode: SolveMode) {
        self.mode = mode
    }

    /// Recebe o texto acumulado ate agora e devolve apenas os trechos novos.
    public mutating func feed(_ accumulated: String) -> [SpeechSegment] {
        let ns = accumulated as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if Self.unreadableRegex.firstMatch(in: accumulated, range: whole) != nil {
            unreadable = true
        }
        guard !unreadable else { return [] }

        var raw: [(kind: String, text: String)] = []
        var steps = 0
        for m in Self.fieldRegex.matches(in: accumulated, range: whole) {
            let key = ns.substring(with: m.range(at: 1))
            let value = Self.unescape(ns.substring(with: m.range(at: 2)))
            switch key {
            case "questao_falada":
                raw.append(("questao", value))
            case "enunciado_falado":
                raw.append(("enunciado", value))
            case "plano_falado" where mode == .tutor:
                raw.append(("plano", value))
            case "falado" where mode != .ditado:
                steps += 1
                if mode == .tutor || steps <= 2 { raw.append(("passo", value)) }
            case "resposta_falada" where mode != .ditado:
                raw.append(("resposta", value.isEmpty ? "Não consegui formular a resposta final." : value))
            default:
                break
            }
        }

        guard raw.count > rawEmitted else { return [] }
        var out: [SpeechSegment] = []
        for item in raw[rawEmitted...] {
            let clean = SpeechSanitizer.sanitize(item.text)
            guard !clean.isEmpty else { continue }
            segmentCount += 1
            out.append(SpeechSegment(id: segmentCount, kind: item.kind, text: clean))
        }
        rawEmitted = raw.count
        return out
    }

    private static func unescape(_ body: String) -> String {
        let quoted = Data("\"\(body)\"".utf8)
        return (try? JSONDecoder().decode(String.self, from: quoted)) ?? body
    }
}
