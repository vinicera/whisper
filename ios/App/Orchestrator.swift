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

    // MARK: - Folha (varias questoes na mesma foto)

    /// A foto atual e as questoes encontradas nela.
    struct Sheet {
        let image: EncodedImage
        var labels: [String]
        var current: Int  // 1 = primeira

        var hasNext: Bool { current < labels.count }
    }

    @Published private(set) var sheet: Sheet?
    /// Proxima questao ja pedida em segundo plano enquanto o aluno ouve a atual.
    private var prefetch: (index: Int, task: Task<SolveResponse, Error>)?

    /// Toques nos oculos. O significado de 1 toque depende do momento.
    private func handle(_ action: RemoteControl.Action) {
        if isBusy && speech.segments.isEmpty {
            // Nada chegou ainda: qualquer toque so informa o andamento.
            let seconds = workingSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            speech.interject("Ainda resolvendo. \(SpeechService.numberWord(seconds)) segundos.")
            return
        }
        guard !speech.segments.isEmpty else {
            // Sem resposta: 1 toque resolve a ultima foto (ex.: tirada pelo botao dos oculos).
            if action == .togglePause {
                solveLatestPhoto()
            } else {
                speech.announce("Nenhuma resposta ainda. Tire a foto da questão e toque uma vez.")
            }
            return
        }
        switch action {
        case .togglePause:
            if speech.isSpeaking || speech.isPaused {
                speech.togglePause()
            } else if isBusy {
                speech.interject("Ainda chegando o resto da resolução.")
            } else {
                advance()
            }
        case .repeatCurrent: speech.repeatCurrent()
        case .previous: speech.previous()
        case .next: speech.next()
        case .jumpToAnswer: speech.jumpToAnswer()
        }
    }

    /// Fim da resposta + 1 toque: foto nova (se houver) ou proxima questao da folha.
    private func advance() {
        if let latest = ImageLoader.latestPhotoDate(),
           latest > (sheet?.image.capturedAt ?? .distantPast).addingTimeInterval(1),
           settings.maxPhotoAgeMinutes == 0 || Date().timeIntervalSince(latest) < Double(settings.maxPhotoAgeMinutes * 60) {
            log("Foto nova na galeria: nova folha")
            solveLatestPhoto()
            return
        }
        guard let sheet, sheet.hasNext else {
            if let sheet, sheet.labels.count > 1 {
                speech.announce("Essa era a última questão desta folha. Para outra folha, tire uma nova foto e toque uma vez.")
            } else {
                speech.announce("Para outra questão, tire uma nova foto e toque uma vez.")
            }
            return
        }
        nextQuestion()
    }

    func nextQuestion() {
        guard let sheet, sheet.hasNext else { return }
        let index = sheet.current + 1
        let ready = prefetch?.index == index ? prefetch?.task : nil
        prefetch = nil
        run(origin: "questão \(index) da folha", greeting: "Próxima questão.", sheetIndex: index,
            prefetched: ready) { sheet.image }
    }

    /// Texto enviado ao modelo para manter a numeracao da primeira leitura.
    private func hint(for index: Int, in sheet: Sheet) -> String {
        let list = sheet.labels.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; ")
        return "posição \(index) de \(sheet.labels.count) na lista desta folha: \(list)"
    }

    /// Pede a proxima questao em segundo plano (sem falar nada).
    private func startPrefetch() {
        prefetch?.task.cancel()
        prefetch = nil
        guard let sheet, sheet.hasNext, let provider = try? makeBackgroundProvider() else { return }
        let index = sheet.current + 1
        let options = SolveOptions(mode: settings.solveMode, questionHint: hint(for: index, in: sheet))
        let image = sheet.image
        log("Adiantando a questão \(index) em segundo plano")
        prefetch = (index, Task { try await provider.solve(image, options: options) })
    }

    /// Depois da resposta: diz o que o proximo toque faz.
    private func announceNextHint() {
        guard let sheet else { return }
        if sheet.hasNext {
            speech.interject("Toque uma vez para a próxima questão.")
        } else if sheet.labels.count > 1 {
            speech.interject("Essa era a última questão desta folha.")
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

    /// `sheetIndex` nil = foto nova (nova folha); senao, questao `sheetIndex` da folha atual.
    private func run(origin: String, greeting: String = "Recebido. Resolvendo.", sheetIndex: Int? = nil,
                     prefetched: Task<SolveResponse, Error>? = nil,
                     load: @escaping () async throws -> EncodedImage) {
        task?.cancel()
        stopWatchdog()
        timedOut = false
        if sheetIndex == nil {
            prefetch?.task.cancel()
            prefetch = nil
        }
        speech.speechRateSync(settings.speechRate)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .working("Lendo a foto")
                self.speech.announce(greeting)
                let image = try await load()
                self.log("Imagem (\(origin)): \(image.width)x\(image.height), \(image.jpeg.count / 1024) KB")

                self.phase = .working("Escolhendo conexão")
                let provider = try await self.chooseProvider()
                self.lastProviderLabel = provider.label

                self.phase = .working(sheetIndex.map { "Questão \($0) da folha" } ?? "Resolvendo (\(provider.label))")
                let started = Date()
                self.startWatchdog()
                self.streamedCount = 0
                self.speech.beginStream()

                var ready: SolveResponse?
                if let prefetched {
                    ready = try? await prefetched.value
                    self.log(ready == nil ? "A questão adiantada falhou; resolvendo agora"
                                          : "Questão já estava pronta (adiantada)")
                }
                var options = SolveOptions(mode: self.settings.solveMode)
                if let sheetIndex, let sheet = self.sheet {
                    options.questionHint = self.hint(for: sheetIndex, in: sheet)
                }
                let response: SolveResponse
                if let ready {
                    response = ready
                } else {
                    response = try await provider.solve(image, options: options) { [weak self] segment in
                        guard let self, !Task.isCancelled else { return }
                        if self.streamedCount == 0 {
                            let s = String(format: "%.1f", Date().timeIntervalSince(started))
                            self.log("Começou a falar em \(s)s")
                        }
                        self.streamedCount += 1
                        self.lastActivity = Date()
                        self.speech.append(segment)
                    }
                }
                self.stopWatchdog()
                try Task.checkCancellation()

                // Atualiza a folha: nova (foto nova) ou avanca na atual.
                let labels = response.questoes ?? []
                if let sheetIndex, var sheet = self.sheet {
                    sheet.current = sheetIndex
                    self.sheet = sheet
                } else {
                    self.sheet = Sheet(image: image, labels: labels, current: response.questaoAtual ?? 1)
                    if labels.count > 1 { self.log("Folha com \(labels.count) questões: \(labels.joined(separator: " | "))") }
                }

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
                } else {
                    self.speech.speak(segments: response.speech.segments.isEmpty
                        ? [SpeechSegment(id: 1, kind: "aviso", text: response.speech.fullText)]
                        : response.speech.segments)
                }
                if response.status == .ok {
                    self.announceNextHint()
                    self.startPrefetch()
                }
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

    /// Provedor para trabalho em segundo plano: nao fala e nao mexe no cronometro.
    private func makeBackgroundProvider() throws -> SolveProvider {
        if settings.connection == .bridge, let url = settings.bridgeBaseURL {
            return BridgeProvider(baseURL: url, token: settings.bridgeToken)
        }
        guard settings.isDirectConfigured else { throw ProviderError.notConfigured("sem chave do Gemini") }
        return DirectGeminiProvider(
            apiKey: settings.geminiKey,
            model: settings.geminiModel,
            thinkingLevel: settings.thinkingLevel,
            log: { [weak self] message in self?.log("(adiantada) \(message)") })
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
