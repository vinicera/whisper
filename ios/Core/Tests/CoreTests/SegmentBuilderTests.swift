import Foundation
import XCTest
@testable import Core

final class SegmentBuilderTests: XCTestCase {
    /// JSON no formato que o Gemini devolve (snake_case, como no server/app/models.py).
    private let geminiJSON = """
    {"legivel": true,
     "enunciado_latex": "\\\\frac{d}{dx} x^2",
     "enunciado_falado": "Calcule a derivada de x^2.",
     "tipo": "derivada",
     "plano_falado": "Vamos usar a regra da potência.",
     "sympy": {"expr": "x**2", "var": "x", "operacao": "derivar", "ordem": null,
               "tende_a": null, "resultado": "2*x"},
     "passos": [{"falado": "Desce o expoente.", "latex": ""},
                {"falado": "Subtrai um do expoente.", "latex": ""},
                {"falado": "Simplifica.", "latex": ""}],
     "resposta_falada": "A resposta final é dois x.",
     "resposta_latex": "2x"}
    """

    private func decode() throws -> ModelAnswer {
        try Contract.decoder.decode(ModelAnswer.self, from: Data(geminiJSON.utf8))
    }

    func testDecodesGeminiAnswer() throws {
        let a = try decode()
        XCTAssertTrue(a.legivel)
        XCTAssertEqual(a.sympy?.tendeA, nil)
        XCTAssertEqual(a.sympy?.resultado, "2*x")
        XCTAssertEqual(a.passos?.count, 3)
    }

    func testTutorHasAllStepsAndSanitizes() throws {
        let segs = SegmentBuilder.segments(from: try decode(), mode: .tutor)
        XCTAssertEqual(segs.map(\.kind), ["enunciado", "plano", "passo", "passo", "passo", "resposta"])
        XCTAssertTrue(segs[0].text.contains("x ao quadrado"), segs[0].text)
        for s in segs { XCTAssertEqual(SpeechSanitizer.forbidden(in: s.text), []) }
    }

    func testRespostaModeLimitsSteps() throws {
        let segs = SegmentBuilder.segments(from: try decode(), mode: .resposta)
        XCTAssertEqual(segs.map(\.kind), ["enunciado", "passo", "passo", "resposta"])
    }

    func testDitadoOnlyStatement() throws {
        XCTAssertEqual(SegmentBuilder.segments(from: try decode(), mode: .ditado).map(\.kind), ["enunciado"])
    }

    func testUnreadable() {
        let r = SegmentBuilder.response(from: ModelAnswer(legivel: false), mode: .tutor)
        XCTAssertEqual(r.status, .unreadable)
        XCTAssertFalse(r.speech.fullText.isEmpty)
    }
}
