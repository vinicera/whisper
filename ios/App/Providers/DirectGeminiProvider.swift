import Core
import Foundation

/// Modo Direto: o iPhone chama a API do Gemini sem passar pelo PC (sem verificacao SymPy).
/// Usa streaming: os trechos falados saem assim que o modelo termina de escreve-los.
struct DirectGeminiProvider: SolveProvider {
    let apiKey: String
    let model: String
    /// "low", "medium", "high"... ou vazio para o padrao do modelo (mais lento).
    var thinkingLevel: String = "low"
    /// Eventos de diagnostico (vao para o registro de depuracao).
    var log: @MainActor (String) -> Void = { _ in }
    /// Chamado a cada pedaco recebido (sinal de vida, mesmo sem trecho completo).
    var onProgress: @MainActor () -> Void = {}
    /// Aviso curto para falar ao aluno (ex.: "tentando de novo").
    var notice: @MainActor (String) -> Void = { _ in }

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

        var answerText: String {
            (candidates?.first?.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
        }
    }

    func solve(_ image: EncodedImage, options: SolveOptions) async throws -> SolveResponse {
        try await solve(image, options: options, onSegment: { _ in })
    }

    func solve(_ image: EncodedImage, options: SolveOptions,
               onSegment: @escaping SegmentHandler) async throws -> SolveResponse {
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("A chave do Gemini não está configurada. Abra as configurações do app.")
        }
        let modelId = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):streamGenerateContent?alt=sse")
        else { throw ProviderError.notConfigured("Nome de modelo inválido: \(modelId)") }

        let level = thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        var thinking: String? = level.isEmpty ? nil : level
        // Sobrecarga do Google (503 etc.) costuma passar em segundos: tenta de novo antes de desistir.
        let retryDelays: [UInt64] = [2, 5, 10]
        var attempt = 0
        while true {
            do {
                return try await call(url: url, image: image, options: options,
                                      thinking: thinking, onSegment: onSegment)
            } catch ProviderError.http(400, let message) where thinking != nil && message.lowercased().contains("think") {
                // Modelo que nao aceita thinkingLevel: tenta de novo sem limitar o raciocinio.
                await log("O modelo recusou o nível de raciocínio (\(level)); tentando sem limite.")
                thinking = nil
            } catch ProviderError.http(let code, _) where [500, 502, 503, 504].contains(code) && attempt < retryDelays.count {
                let wait = retryDelays[attempt]
                attempt += 1
                await log("Gemini sobrecarregado (\(code)); tentativa \(attempt + 1) em \(wait)s")
                await notice("O Gemini está sobrecarregado. Tentando de novo.")
                await onProgress()
                try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                await onProgress()
            }
        }
    }

    private func call(url: URL, image: EncodedImage, options: SolveOptions, thinking: String?,
                      onSegment: @escaping SegmentHandler) async throws -> SolveResponse {
        let imagePart: [String: Any] = ["inlineData": ["mimeType": image.mime, "data": image.base64]]
        let textPart: [String: Any] = ["text": Prompt.userMessage(options)]
        let userContent: [String: Any] = ["role": "user", "parts": [imagePart, textPart]]
        var generation: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": GeminiSchema.modelAnswer,
            "temperature": 0.2,
            // Teto contra loops de saida estruturada (uma resolucao longa usa bem menos).
            "maxOutputTokens": 16384,
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

        await log("Enviando ao Gemini (\((req.httpBody?.count ?? 0) / 1024) KB, raciocínio: \(thinking ?? "padrão"))")
        let started = Date()
        func elapsed() -> String { String(format: "%.1f", Date().timeIntervalSince(started)) }

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            // Erro pode vir como JSON unico ou como lista.
            let message = (try? JSONDecoder().decode(GeminiResponse.self, from: data))?.error?.message
                ?? (try? JSONDecoder().decode([GeminiResponse].self, from: data))?.first?.error?.message
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            await log("Gemini HTTP \(code) em \(elapsed())s")
            throw ProviderError.http(code, message)
        }

        var text = ""
        var extractor = StreamingSegmentExtractor(mode: options.mode)
        var usage: GeminiResponse.Usage?
        var finish: String?
        var chunks = 0
        var undecodable = 0
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let chunk = try? JSONDecoder().decode(GeminiResponse.self, from: Data(payload.utf8)) else {
                    undecodable += 1
                    continue
                }
                chunks += 1
                await onProgress()
                if let message = chunk.error?.message { throw ProviderError.http(code, message) }
                usage = chunk.usageMetadata ?? usage
                finish = chunk.candidates?.first?.finishReason ?? finish
                let piece = chunk.answerText
                guard !piece.isEmpty else { continue }
                if text.isEmpty { await log("Primeiro texto do Gemini em \(elapsed())s") }
                text += piece
                for segment in extractor.feed(text) {
                    await log("Trecho \(segment.id) (\(segment.kind)) em \(elapsed())s")
                    await onSegment(segment)
                }
                if Self.looksStuck(text) {
                    throw ProviderError.badResponse("O Gemini entrou em repetição e não terminou a resposta.")
                }
            }
        } catch {
            // Diagnostico: o que o modelo estava escrevendo quando parou.
            let tail = String(text.suffix(160)).replacingOccurrences(of: "\n", with: "⏎")
            await log("Interrompido em \(elapsed())s · \(chunks) pedaços, \(text.count) caracteres"
                + (undecodable > 0 ? ", \(undecodable) ilegíveis" : "") + " · fim do texto: «\(tail)»")
            throw error
        }

        if let u = usage {
            await log("Gemini terminou em \(elapsed())s · tokens: entrada \(u.promptTokenCount ?? 0), "
                + "raciocínio \(u.thoughtsTokenCount ?? 0), saída \(u.candidatesTokenCount ?? 0)")
        } else {
            await log("Gemini terminou em \(elapsed())s")
        }
        guard !text.isEmpty else {
            throw ProviderError.badResponse("Resposta vazia (\(finish ?? "sem motivo")).")
        }
        let answer: ModelAnswer
        do {
            answer = try Contract.decoder.decode(ModelAnswer.self, from: Data(text.utf8))
        } catch {
            throw ProviderError.badResponse("JSON fora do esquema (\(finish ?? "sem motivo")).")
        }
        return SegmentBuilder.response(from: answer, mode: options.mode)
    }

    /// Defeito conhecido de saida estruturada: o modelo repete espacos/quebras ou o mesmo
    /// pedaco sem fechar o JSON. Detecta para falhar rapido em vez de esperar o limite.
    static func looksStuck(_ text: String) -> Bool {
        guard text.count > 600 else { return false }
        let tail = String(text.suffix(400))
        if tail.allSatisfy({ $0.isWhitespace }) { return true }
        for unit in 1...40 {
            let piece = String(tail.suffix(unit))
            if tail.hasSuffix(String(repeating: piece, count: 400 / unit)) { return true }
        }
        return false
    }
}
