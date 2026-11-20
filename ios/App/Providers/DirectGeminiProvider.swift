import Core
import Foundation

/// Modo Direto: o iPhone chama a API do Gemini sem passar pelo PC (sem verificacao SymPy).
struct DirectGeminiProvider: SolveProvider {
    let apiKey: String
    let model: String
    /// "low", "medium", "high"... ou vazio para o padrao do modelo (mais lento).
    var thinkingLevel: String = "low"
    /// Eventos de diagnostico (vao para o registro de depuracao).
    var log: @MainActor (String) -> Void = { _ in }

    var label: String { "Direto (\(model))" }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
        }
        struct APIError: Decodable { let message: String? }
        let candidates: [Candidate]?
        let usageMetadata: Usage?
        let error: APIError?
    }

    func solve(_ image: EncodedImage, options: SolveOptions) async throws -> SolveResponse {
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("A chave do Gemini não está configurada. Abra as configurações do app.")
        }
        let modelId = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent")
        else { throw ProviderError.notConfigured("Nome de modelo inválido: \(modelId)") }

        let level = thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await call(url: url, image: image, options: options, thinking: level.isEmpty ? nil : level)
        } catch ProviderError.http(400, let message) where !level.isEmpty && message.lowercased().contains("think") {
            // Modelo que nao aceita thinkingLevel: tenta de novo sem limitar o raciocinio.
            await log("O modelo recusou o nível de raciocínio (\(level)); tentando sem limite.")
            return try await call(url: url, image: image, options: options, thinking: nil)
        }
    }

    private func call(url: URL, image: EncodedImage, options: SolveOptions, thinking: String?) async throws -> SolveResponse {
        let imagePart: [String: Any] = ["inlineData": ["mimeType": image.mime, "data": image.base64]]
        let textPart: [String: Any] = ["text": Prompt.userMessage(options)]
        let userContent: [String: Any] = ["role": "user", "parts": [imagePart, textPart]]
        var generation: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": GeminiSchema.modelAnswer,
            "temperature": 0.2,
        ]
        if let thinking {
            generation["thinkingConfig"] = ["thinkingLevel": thinking]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompt.system]]],
            "contents": [userContent],
            "generationConfig": generation,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        await log("Enviando ao Gemini (\((req.httpBody?.count ?? 0) / 1024) KB,raciocínio: \(thinking ?? "padrão"))")
        let started = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data)

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if let u = decoded?.usageMetadata {
            await log("Gemini HTTP \(code) em \(seconds)s · tokens: entrada \(u.promptTokenCount ?? 0), "
                + "raciocínio \(u.thoughtsTokenCount ?? 0), saída \(u.candidatesTokenCount ?? 0)")
        } else {
            await log("Gemini HTTP \(code) em \(seconds)s")
        }

        guard code == 200 else {
            throw ProviderError.http(code, decoded?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        let parts = decoded?.candidates?.first?.content?.parts ?? []
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
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
