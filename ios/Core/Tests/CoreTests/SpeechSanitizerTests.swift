import Foundation
import XCTest
@testable import Core

final class SpeechSanitizerTests: XCTestCase {
    private struct CaseFile: Decodable {
        struct Case: Decodable {
            let input: String
            let must_contain: [String]
        }
        let cases: [Case]
    }

    /// Mesmo arquivo usado pelo pytest do servidor.
    private func loadSharedCases() throws -> [CaseFile.Case] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // raiz do repo
        let url = repo.appendingPathComponent("shared/contract/sanitizer_cases.json")
        return try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: url)).cases
    }

    func testSharedCases() throws {
        let cases = try loadSharedCases()
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let out = SpeechSanitizer.sanitize(c.input)
            XCTAssertEqual(SpeechSanitizer.forbidden(in: out), [], "entrada: \(c.input) -> \(out)")
            for piece in c.must_contain {
                XCTAssertTrue(out.contains(piece), "'\(piece)' ausente em '\(out)'")
            }
        }
    }

    func testPlainTextUntouched() {
        let text = "A resposta final é dois x seno de x, mais x ao quadrado vezes cosseno de x."
        XCTAssertEqual(SpeechSanitizer.sanitize(text), text)
    }

    func testHyphenatedWordKept() {
        XCTAssertTrue(SpeechSanitizer.sanitize("Vamos passo-a-passo.").contains("passo-a-passo"))
    }

    func testContractRoundTrip() throws {
        let json = """
        {"request_id":"r1","status":"ok",
         "speech":{"full_text":"Oi.","segments":[{"id":1,"kind":"resposta","text":"Oi."}],
                   "lang":"pt-BR","estimated_seconds":1},
         "verification":{"performed":true,"passed":true,"engine":"sympy","notes":null},
         "error":null,"debug":{"model":"fake"}}
        """
        let r = try Contract.decoder.decode(SolveResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.speech.segments.first?.kind, "resposta")

        let req = SolveRequest(requestId: "r1",
                               client: ClientInfo(appVersion: "0.1.0", device: "test"),
                               image: ImagePayload(base64: "AAAA", source: .photoLibrary))
        let encoded = String(decoding: try Contract.encoder.encode(req), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"request_id\""))
        XCTAssertTrue(encoded.contains("\"photo_library\""))
        XCTAssertTrue(encoded.contains("\"passo_a_passo\""))
        XCTAssertTrue(encoded.contains("\"max_speech_seconds\""))
    }
}
