import Foundation
import XCTest
@testable import Core

final class StreamingSegmentsTests: XCTestCase {
    private let json = """
    {"legivel": true,
     "questoes_na_folha": ["questão um", "questão dois, item a"],
     "questao_atual": 1,
     "questao_falada": "Esta folha tem duas questões. Começando pela questão um.",
     "enunciado_latex": "\\\\lim_{x \\\\to 0} \\\\frac{\\\\sin x}{x}",
     "enunciado_falado": "Calcule o limite quando x tende a zero de seno de x sobre x.",
     "tipo": "limite",
     "plano_falado": "Vamos usar o limite fundamental.",
     "sympy": {"expr": "sin(x)/x", "var": "x", "operacao": "limite", "tende_a": "0", "resultado": "1"},
     "passos": [{"falado": "Uma fração. Em cima, seno de x. Embaixo, x.", "latex": "\\\\frac{\\\\sin x}{x}"},
                {"falado": "Esse é o limite fundamental. Resultado: um.", "latex": ""},
                {"falado": "Diz-se \\"limite notável\\".", "latex": ""}],
     "resposta_falada": "A resposta final é um.",
     "resposta_latex": "1"}
    """

    /// Alimenta o JSON aos pedacos e junta tudo o que foi emitido.
    private func streamed(_ mode: SolveMode, chunk: Int) -> [SpeechSegment] {
        var extractor = StreamingSegmentExtractor(mode: mode)
        var out: [SpeechSegment] = []
        var acc = ""
        var i = json.startIndex
        while i < json.endIndex {
            let end = json.index(i, offsetBy: chunk, limitedBy: json.endIndex) ?? json.endIndex
            acc += json[i..<end]
            out += extractor.feed(acc)
            i = end
        }
        return out
    }

    private func complete(_ mode: SolveMode) throws -> [SpeechSegment] {
        let answer = try Contract.decoder.decode(ModelAnswer.self, from: Data(json.utf8))
        return SegmentBuilder.segments(from: answer, mode: mode)
    }

    func testStreamingMatchesCompleteForEveryMode() throws {
        for mode in [SolveMode.tutor, .resposta, .ditado] {
            for chunk in [1, 7, 50, 10_000] {
                let s = streamed(mode, chunk: chunk)
                let c = try complete(mode)
                XCTAssertEqual(s.map(\.kind), c.map(\.kind), "modo \(mode) pedaço \(chunk)")
                XCTAssertEqual(s.map(\.text), c.map(\.text), "modo \(mode) pedaço \(chunk)")
                XCTAssertEqual(s.map(\.id), Array(1...c.count))
            }
        }
    }

    func testEmitsStatementBeforeTheRestArrives() {
        var extractor = StreamingSegmentExtractor(mode: .tutor)
        let cut = json.range(of: "\"tipo\"")!.lowerBound
        let first = extractor.feed(String(json[..<cut]))
        XCTAssertEqual(first.map(\.kind), ["questao", "enunciado"])
        XCTAssertTrue(extractor.feed(String(json[..<cut])).isEmpty)  // nada repetido
    }

    func testSheetInfoReachesResponse() throws {
        let answer = try Contract.decoder.decode(ModelAnswer.self, from: Data(json.utf8))
        let r = SegmentBuilder.response(from: answer, mode: .tutor)
        XCTAssertEqual(r.questoes, ["questão um", "questão dois, item a"])
        XCTAssertEqual(r.questaoAtual, 1)
        XCTAssertEqual(r.speech.segments.first?.kind, "questao")
    }

    func testIncompleteStringIsNotEmitted() {
        var extractor = StreamingSegmentExtractor(mode: .tutor)
        XCTAssertTrue(extractor.feed(#"{"legivel": true, "enunciado_falado": "Calcule o lim"#).isEmpty)
    }

    func testUnreadableEmitsNothing() {
        var extractor = StreamingSegmentExtractor(mode: .tutor)
        let out = extractor.feed(#"{"legivel": false, "motivo_ilegivel_falado": "Aproxime a câmera."}"#)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(extractor.unreadable)
    }
}
