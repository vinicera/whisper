import AVFoundation
import Core

/// TTS em pt-BR. Com os oculos conectados, o iOS roteia `.playback` para eles (A2DP).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published private(set) var lastSpoken = ""

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var currentRouteDescription: String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
    }

    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .spokenAudio faz outros apps (podcast) pausarem em vez de so abaixar.
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    /// Fala o texto depois de passar pelo sanitizador (ultima barreira).
    func speak(_ raw: String) {
        let text = SpeechSanitizer.sanitize(raw)
        guard !text.isEmpty else { return }
        do { try activateSession() } catch { print("AudioSession: \(error)") }

        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestPortugueseVoice()
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.1
        lastSpoken = text
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Prefere vozes "premium/enhanced" em pt-BR, se o usuario as baixou em Ajustes > Acessibilidade.
    static func bestPortugueseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pt-BR" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "pt-BR")
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
