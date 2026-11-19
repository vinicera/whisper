import Core
import Foundation

/// Modo Direto: o iPhone chama a API do Gemini sem passar pelo PC (sem verificacao SymPy).
struct DirectGeminiProvider: SolveProvider {
    let apiKey: String
    let model: String

    var label: String { "Direto (\(model))" }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct APIError: Decodable { let message: String? }
        let candidates: [Candidate]?
        let error: APIError?
    }

    func solve(_ image: EncodedImage, options: SolveOptions) async throws -> SolveResponse {
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("A chave do Gemini não está configurada. Abra as configurações do app.")
        }
        let modelId = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent")
        else { throw ProviderError.notConfigured("Nome de modelo inválido: \(modelId)") }

        let imagePart: [String: Any] = ["inlineData": ["mimeType": image.mime, "data": image.base64]]
        let textPart: [String: Any] = ["text": Prompt.userMessage(options)]
        let userContent: [String: Any] = ["role": "user", "parts": [imagePart, textPart]]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompt.system]]],
            "contents": [userContent],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": GeminiSchema.modelAnswer,
                "temperature": 0.2,
            ] as [String: Any],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data)
        guard code == 200 else {
            throw ProviderError.http(code, decoded?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        let text = decoded?.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        guard !text.isEmpty else {
            throw ProviderError.badResponse("Resposta vazia (\(decoded?.candidates?.first?.finishReason ?? "sem motivo")).")
        }
        let answer: ModelAnswer
        do {
            answer = try Contract.decoder.decode(ModelAnswer.self, from: Data(text.utf8))
        } catch {
            throw ProviderError.badResponse("JSON fora do esquema.")
        }
        return SegmentBuilder.response(from: answer, mode: options.mode)
    }
}
