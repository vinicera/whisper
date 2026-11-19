import AVFoundation
import Core

/// TTS em pt-BR. Com os oculos conectados, o iOS roteia `.playback` para eles (A2DP).
/// Fala a resposta em segmentos, para permitir repetir/avancar/voltar passos.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var currentIndex: Int?
    /// 0...1 (0,5 = ritmo normal do iOS)
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

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
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession: \(error)")
        }
    }

    // MARK: - Falar

    /// Aviso curto e avulso ("Recebido, resolvendo"). Nao altera os segmentos guardados.
    func announce(_ raw: String) {
        stop()
        enqueue(raw, index: nil)
    }

    /// Fala a resposta a partir de um segmento.
    func speak(segments newSegments: [SpeechSegment], from start: Int = 0) {
        stop()
        segments = newSegments
        guard !newSegments.isEmpty else { return }
        let first = max(0, min(start, newSegments.count - 1))
        for i in first..<newSegments.count {
            enqueue(newSegments[i].text, index: i)
        }
    }

    func repeatCurrent() {
        guard !segments.isEmpty else { return }
        speak(segments: segments, from: currentIndex ?? 0)
    }

    func next() {
        guard !segments.isEmpty else { return }
        speak(segments: segments, from: min((currentIndex ?? -1) + 1, segments.count - 1))
    }

    func previous() {
        guard !segments.isEmpty else { return }
        speak(segments: segments, from: max((currentIndex ?? 1) - 1, 0))
    }

    func stop() {
        live.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    private func enqueue(_ raw: String, index: Int?) {
        let text = SpeechSanitizer.sanitize(raw)
        guard !text.isEmpty else { return }
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestPortugueseVoice()
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.25
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
    }

    /// Prefere vozes "premium/aprimorada" em pt-BR, se baixadas em Ajustes > Acessibilidade > Conteúdo Falado.
    static func bestPortugueseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pt-BR" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "pt-BR")
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
