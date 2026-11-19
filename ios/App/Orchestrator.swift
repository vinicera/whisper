import Core
import Foundation
import UIKit

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

/// Coordena o fluxo: obter imagem -> escolher provedor -> resolver -> falar.
@MainActor
final class Orchestrator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastResponse: SolveResponse?
    @Published private(set) var lastProviderLabel = ""
    @Published private(set) var logs: [LogEntry] = []

    let settings: AppSettings
    let speech: SpeechService
    private var task: Task<Void, Never>?

    init(settings: AppSettings, speech: SpeechService) {
        self.settings = settings
        self.speech = speech
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    // MARK: - Entradas

    func solveLatestPhoto() {
        let maxAge = settings.maxPhotoAgeMinutes
        run(origin: "última foto") { try await ImageLoader.latestPhoto(maxAgeMinutes: maxAge) }
    }

    func solve(image: UIImage, source: ImageSourceKind) {
        run(origin: source == .camera ? "câmera" : "galeria") {
            try ImageLoader.encode(image, source: source)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        speech.stop()
        phase = .idle
    }

    // MARK: - Fluxo

    private func run(origin: String, load: @escaping () async throws -> EncodedImage) {
        task?.cancel()
        speech.speechRateSync(settings.speechRate)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .working("Lendo a foto")
                self.speech.announce("Recebido. Resolvendo.")
                let image = try await load()
                self.log("Imagem (\(origin)): \(image.width)x\(image.height), \(image.jpeg.count / 1024) KB")

                self.phase = .working("Escolhendo conexão")
                let provider = try await self.chooseProvider()
                self.lastProviderLabel = provider.label

                self.phase = .working("Resolvendo (\(provider.label))")
                let started = Date()
                let options = SolveOptions(mode: self.settings.solveMode)
                let response = try await provider.solve(image, options: options)
                try Task.checkCancellation()

                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let verified = response.verification.passed.map { $0 ? "sim" : "NÃO" } ?? "não se aplica"
                self.log("\(provider.label): \(response.status.rawValue) em \(seconds)s · verificado: \(verified)")
                if let notes = response.verification.notes { self.log("Verificação: \(notes)") }
                if let err = response.error { self.log("Erro \(err.code): \(err.message ?? "")") }

                self.lastResponse = response
                self.phase = .idle
                self.speech.speak(segments: response.speech.segments.isEmpty
                    ? [SpeechSegment(id: 1, kind: "aviso", text: response.speech.fullText)]
                    : response.speech.segments)
            } catch is CancellationError {
                self.log("Cancelado")
            } catch let error as URLError where error.code == .cancelled {
                self.log("Cancelado")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.log("Erro: \(message)")
                self.phase = .failed(message)
                self.speech.announce(message)
            }
        }
    }

    private func chooseProvider() async throws -> SolveProvider {
        let direct = DirectGeminiProvider(apiKey: settings.geminiKey, model: settings.geminiModel)
        let bridge = settings.bridgeBaseURL.map { BridgeProvider(baseURL: $0, token: settings.bridgeToken) }

        switch settings.connection {
        case .direct:
            return direct
        case .bridge:
            guard let bridge else {
                throw ProviderError.notConfigured("O endereço da ponte não está configurado.")
            }
            return bridge
        case .auto:
            if let bridge {
                if let health = await bridge.health(timeout: 3) {
                    log("Ponte disponível (\(health.llmProvider):\(health.model))")
                    return bridge
                }
                log("Ponte não respondeu em 3s; usando Gemini direto")
            }
            guard settings.isDirectConfigured else {
                throw ProviderError.notConfigured(
                    "Nenhuma conexão disponível. Ligue o servidor no PC ou configure a chave do Gemini.")
            }
            return direct
        }
    }

    func testBridge() async -> String {
        guard let url = settings.bridgeBaseURL else { return "Endereço da ponte vazio." }
        let bridge = BridgeProvider(baseURL: url, token: settings.bridgeToken)
        if let h = await bridge.health(timeout: 5) {
            return "Conectado: servidor \(h.version), \(h.llmProvider) \(h.model)"
        }
        return "Sem resposta de \(url.absoluteString)"
    }

    func log(_ text: String) {
        logs.insert(LogEntry(text: text), at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }
}

extension SpeechService {
    /// A velocidade fica salva em AppSettings; aplica antes de falar.
    func speechRateSync(_ value: Double) {
        rate = Float(value)
    }
}
