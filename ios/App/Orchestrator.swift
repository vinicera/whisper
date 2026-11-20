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
    /// Inicio da resolucao em andamento (para o cronometro na tela).
    @Published private(set) var workingSince: Date?

    let settings: AppSettings
    let speech: SpeechService
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    /// Trechos ja falados durante o streaming da resolucao atual.
    private var streamedCount = 0
    /// Ultimo sinal de vida do modelo (o limite de tempo conta a partir dele).
    private var lastActivity = Date()

    /// Tempo maximo de uma resolucao antes de desistir com aviso.
    static let solveTimeout: TimeInterval = 75
    /// Teto absoluto, mesmo com o modelo mandando dados.
    static let totalLimit: TimeInterval = 180
    /// Intervalo do aviso falado "ainda resolvendo".
    static let heartbeatInterval: TimeInterval = 15

    let remote = RemoteControl()

    init(settings: AppSettings, speech: SpeechService) {
        self.settings = settings
        self.speech = speech
        remote.onLog = { [weak self] message in self?.log(message) }
        remote.onAction = { [weak self] action in self?.handle(action) }
        remote.start()
    }

    /// Toques nos oculos.
    private func handle(_ action: RemoteControl.Action) {
        if isBusy && speech.segments.isEmpty {
            // Nada chegou ainda: qualquer toque so informa o andamento.
            let seconds = workingSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            speech.interject("Ainda resolvendo. \(SpeechService.numberWord(seconds)) segundos.")
            return
        }
        guard !speech.segments.isEmpty else {
            speech.announce("Nenhuma resposta ainda. Peça para tirarem a foto da questão.")
            return
        }
        switch action {
        case .togglePause: speech.togglePause()
        case .repeatCurrent: speech.repeatCurrent()
        case .previous: speech.previous()
        case .next: speech.next()
        case .jumpToAnswer: speech.jumpToAnswer()
        }
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
        stopWatchdog()
        task?.cancel()
        task = nil
        speech.stop()
        phase = .idle
    }

    // MARK: - Fluxo

    private func run(origin: String, load: @escaping () async throws -> EncodedImage) {
        task?.cancel()
        stopWatchdog()
        timedOut = false
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
                self.startWatchdog()
                self.streamedCount = 0
                self.speech.beginStream()
                let options = SolveOptions(mode: self.settings.solveMode)
                let response = try await provider.solve(image, options: options) { [weak self] segment in
                    guard let self, !Task.isCancelled else { return }
                    if self.streamedCount == 0 {
                        let s = String(format: "%.1f", Date().timeIntervalSince(started))
                        self.log("Começou a falar em \(s)s")
                    }
                    self.streamedCount += 1
                    self.lastActivity = Date()
                    self.speech.append(segment)
                }
                self.stopWatchdog()
                try Task.checkCancellation()

                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let verified = response.verification.passed.map { $0 ? "sim" : "NÃO" } ?? "não se aplica"
                self.log("\(provider.label): \(response.status.rawValue) em \(seconds)s · verificado: \(verified)")
                if let notes = response.verification.notes { self.log("Verificação: \(notes)") }
                if let err = response.error { self.log("Erro \(err.code): \(err.message ?? "")") }

                self.lastResponse = response
                self.phase = .idle
                if self.streamedCount > 0 && response.status == .ok {
                    // Ja esta falando: so guarda a versao final para a navegacao por toques.
                    self.speech.finishStream(with: response.speech.segments)
                    return
                }
                self.speech.speak(segments: response.speech.segments.isEmpty
                    ? [SpeechSegment(id: 1, kind: "aviso", text: response.speech.fullText)]
                    : response.speech.segments)
            } catch let error where self.timedOut {
                self.stopWatchdog()
                let message = "O Gemini demorou demais e a resolução foi interrompida. Tente de novo."
                self.log("Erro: tempo esgotado (\(error.localizedDescription))")
                self.phase = .failed(message)
                self.speech.announce(message)
            } catch is CancellationError {
                // cancel()/run() ja pararam o cronometro; nao mexer (pode ser de uma resolucao nova).
                self.log("Cancelado")
            } catch let error as URLError where error.code == .cancelled {
                self.log("Cancelado")
            } catch {
                self.stopWatchdog()
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.log("Erro: \(message)")
                self.phase = .failed(message)
                self.speech.announce(message)
            }
        }
    }

    /// Cronometro + aviso falado periodico + desistencia apos `solveTimeout` sem sinal do modelo.
    private func startWatchdog() {
        stopWatchdog()
        timedOut = false
        workingSince = Date()
        lastActivity = Date()
        let interval: TimeInterval = 5
        let limit = Self.solveTimeout
        let heartbeat = Self.heartbeatInterval
        watchdog = Task { [weak self] in
            var sinceHeartbeat: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let total = self.workingSince.map { Date().timeIntervalSince($0) } ?? 0
                if Date().timeIntervalSince(self.lastActivity) >= limit || total >= Self.totalLimit {
                    self.timedOut = true
                    self.task?.cancel()
                    return
                }
                sinceHeartbeat += interval
                if self.speech.isSpeaking {
                    sinceHeartbeat = 0
                } else if sinceHeartbeat >= heartbeat {
                    sinceHeartbeat = 0
                    self.speech.interject("Ainda resolvendo.")
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        workingSince = nil
    }

    private func chooseProvider() async throws -> SolveProvider {
        let direct = DirectGeminiProvider(
            apiKey: settings.geminiKey,
            model: settings.geminiModel,
            thinkingLevel: settings.thinkingLevel,
            log: { [weak self] message in self?.log(message) },
            onProgress: { [weak self] in self?.lastActivity = Date() },
            notice: { [weak self] message in self?.speech.interject(message) })
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
