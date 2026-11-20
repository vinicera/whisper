import AVFoundation
import Core

/// TTS em pt-BR pensado para quem so ouve: cada parte da resposta e anunciada
/// ("Passo dois de cinco"), as frases saem uma por vez com pausas, e a resposta
/// final e repetida mais devagar no fim. Com os oculos conectados, o iOS roteia
/// `.playback` para eles (A2DP).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var currentIndex: Int?
    /// 0...1 (0,5 = ritmo normal do iOS; mais baixo = mais devagar)
    var rate: Float = 0.42

    /// Pausa entre frases do mesmo trecho e entre trechos (segundos).
    static let sentencePause: TimeInterval = 0.55
    static let segmentPause: TimeInterval = 1.1

    private let synthesizer = AVSpeechSynthesizer()
    /// Utterances ainda na fila -> indice do segmento (nil = aviso avulso).
    private var live: [ObjectIdentifier: Int?] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var currentRouteDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "nenhuma" }
        return outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }

    func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("AudioSession: \(error)")
        }
    }

    // MARK: - Falar

    /// Aviso curto e avulso ("Recebido, resolvendo"). Nao altera os segmentos guardados.
    func announce(_ raw: String) {
        stop()
        enqueue(raw, index: nil, postDelay: 0.2)
    }

    /// Fala a resposta a partir de um segmento, com rotulos e pausas.
    func speak(segments newSegments: [SpeechSegment], from start: Int = 0) {
        stop()
        segments = newSegments
        guard !newSegments.isEmpty else { return }
        let first = max(0, min(start, newSegments.count - 1))
        let stepTotal = newSegments.filter { $0.kind == "passo" }.count
        for i in first..<newSegments.count {
            enqueueSegment(at: i, stepTotal: stepTotal)
        }
    }

    // MARK: - Streaming (fala enquanto o modelo ainda escreve)

    /// Prepara para receber trechos aos poucos. Nao corta o aviso em andamento.
    func beginStream() {
        segments = []
        currentIndex = nil
    }

    /// Acrescenta um trecho que acabou de chegar e o coloca na fila de fala.
    func append(_ segment: SpeechSegment) {
        segments.append(segment)
        enqueueSegment(at: segments.count - 1, stepTotal: nil)
    }

    /// Troca os trechos pela versao final, sem reiniciar a fala.
    func finishStream(with final: [SpeechSegment]) {
        if final.count >= segments.count { segments = final }
    }

    /// Fala algo curto sem interromper a fila (ex.: "ainda resolvendo").
    func interject(_ raw: String) {
        enqueue(raw, index: nil, postDelay: 0.3)
    }

    /// Rotulo + frases com pausas; na resposta final, repete mais devagar.
    /// `stepTotal` nil = ainda nao se sabe quantos passos ha (streaming).
    private func enqueueSegment(at i: Int, stepTotal: Int?) {
        let seg = segments[i]
        if let label = label(for: seg, at: i, in: segments, stepTotal: stepTotal) {
            enqueue(label, index: i, postDelay: 0.35, rateFactor: 0.95)
        }
        let sentences = Self.sentences(seg.text)
        for (k, sentence) in sentences.enumerated() {
            let last = k == sentences.count - 1
            enqueue(sentence, index: i, postDelay: last ? Self.segmentPause : Self.sentencePause)
        }
        if seg.kind == "resposta" {
            // Resposta final de novo, mais devagar: e a parte que o aluno precisa guardar.
            enqueue("Repetindo, mais devagar.", index: i, postDelay: 0.4, rateFactor: 0.95)
            for sentence in sentences {
                enqueue(sentence, index: i, postDelay: Self.sentencePause + 0.3, rateFactor: 0.82)
            }
            enqueue("Fim da resposta.", index: i, postDelay: 0.2, rateFactor: 0.95)
        }
    }

    /// Repete so o trecho atual (com rotulo), sem seguir para os proximos.
    func repeatCurrent() {
        guard !segments.isEmpty else { return }
        speakOnly(currentIndex ?? 0)
    }

    func next() {
        guard !segments.isEmpty else { return }
        let target = (currentIndex ?? -1) + 1
        if target >= segments.count {
            announce("Já está no fim. Último trecho: a resposta final.")
            return
        }
        speak(segments: segments, from: target)
    }

    func previous() {
        guard !segments.isEmpty else { return }
        let target = (currentIndex ?? 0) - 1
        if target < 0 {
            let all = segments
            announce("Já está no começo.")
            segments = all
            currentIndex = 0
            return
        }
        speak(segments: segments, from: target)
    }

    /// Pula direto para a resposta final.
    func jumpToAnswer() {
        guard let i = segments.lastIndex(where: { $0.kind == "resposta" }) else { return }
        speak(segments: segments, from: i)
    }

    func togglePause() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        } else if !segments.isEmpty {
            repeatCurrent()
        }
    }

    func stop() {
        live.removeAll()
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPaused = false
    }

    // MARK: - Montagem

    private func speakOnly(_ index: Int) {
        let all = segments
        stop()
        segments = all
        guard all.indices.contains(index) else { return }
        let seg = all[index]
        let stepTotal = all.filter { $0.kind == "passo" }.count
        if let label = label(for: seg, at: index, in: all, stepTotal: stepTotal) {
            enqueue(label, index: index, postDelay: 0.35, rateFactor: 0.95)
        }
        for sentence in Self.sentences(seg.text) {
            enqueue(sentence, index: index, postDelay: Self.sentencePause + 0.2, rateFactor: 0.9)
        }
    }

    private func label(for seg: SpeechSegment, at index: Int, in all: [SpeechSegment], stepTotal: Int?) -> String? {
        switch seg.kind {
        case "enunciado": return "Enunciado."
        case "plano": return "Estratégia."
        case "passo":
            let n = all[...index].filter { $0.kind == "passo" }.count
            guard let stepTotal else { return "Passo \(Self.numberWord(n))." }
            return "Passo \(Self.numberWord(n)) de \(Self.numberWord(stepTotal))."
        case "resposta": return "Resposta final."
        default: return nil
        }
    }

    /// Quebra em frases para falar uma por vez (pausa entre elas).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == ";" || ch == "?" || ch == "!" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    static func numberWord(_ n: Int) -> String {
        let words = ["zero", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez",
                     "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete", "dezoito",
                     "dezenove", "vinte"]
        return words.indices.contains(n) ? words[n] : String(n)
    }

    private func enqueue(_ raw: String, index: Int?, postDelay: TimeInterval, rateFactor: Float = 1) {
        let text = SpeechSanitizer.sanitize(raw)
        guard !text.isEmpty else { return }
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestPortugueseVoice()
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, rate * rateFactor)
        utterance.postUtteranceDelay = postDelay
        live[ObjectIdentifier(utterance)] = .some(index)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let entry = live[id] else { return }
        if let index = entry { currentIndex = index }
        isSpeaking = true
    }

    fileprivate func didEnd(_ id: ObjectIdentifier) {
        guard live.removeValue(forKey: id) != nil else { return }
        isSpeaking = !live.isEmpty
        if live.isEmpty { isPaused = false }
    }

    /// Prefere vozes "premium/aprimorada" em pt-BR, se baixadas em Ajustes > Acessibilidade > Conteúdo Falado.
    static func bestPortugueseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pt-BR" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "pt-BR")
    }

    static var bestVoiceDescription: String {
        guard let v = bestPortugueseVoice() else { return "nenhuma voz pt-BR" }
        let quality: String
        switch v.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "aprimorada"
        default: quality = "padrão (robótica)"
        }
        return "\(v.name), \(quality)"
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didStart(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didEnd(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didEnd(id) }
    }
}
