import AVFoundation
import MediaPlayer

/// Recebe os toques dos oculos (comandos de midia via Bluetooth) e traduz em acoes.
///
/// Os oculos mandam basicamente "play/pause" a cada toque. Como o aluno so tem
/// esse gesto, contamos toques seguidos:
///   1 toque  -> pausa / continua
///   2 toques -> repete o trecho atual
///   3 toques -> volta um trecho
///   4 toques -> pula para a resposta final
/// Se o aparelho mandar "proxima/anterior faixa", isso avanca/volta um trecho.
@MainActor
final class RemoteControl {
    enum Action: String {
        case togglePause = "pausar/continuar"
        case repeatCurrent = "repetir trecho"
        case previous = "voltar trecho"
        case next = "avançar trecho"
        case jumpToAnswer = "ir para a resposta"
    }

    /// Janela para considerar toques como uma sequencia (segundos).
    static let tapWindow: TimeInterval = 0.7

    var onAction: (Action) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }

    private var tapCount = 0
    private var tapTimer: Task<Void, Never>?
    private var keepAlive: AVAudioPlayer?

    func start() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            command.addTarget { [weak self] event in
                let name = Self.name(of: event.command, in: center)
                Task { @MainActor in self?.registerTap(source: name) }
                return .success
            }
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.fire(.next, source: "próxima faixa") }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.fire(.previous, source: "faixa anterior") }
            return .success
        }
        startKeepAlive()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Whisper",
            MPMediaItemPropertyArtist: "1 toque: pausa ou próxima · 2 repete · 3 volta · 4 resposta",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        onLog("Controle por toques ativo")
    }

    private func registerTap(source: String) {
        tapCount += 1
        onLog("Toque recebido (\(source)), sequência: \(tapCount)")
        tapTimer?.cancel()
        tapTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tapWindow * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let count = self.tapCount
            self.tapCount = 0
            switch count {
            case 1: self.fire(.togglePause, source: "1 toque")
            case 2: self.fire(.repeatCurrent, source: "2 toques")
            case 3: self.fire(.previous, source: "3 toques")
            default: self.fire(.jumpToAnswer, source: "\(count) toques")
            }
        }
    }

    private func fire(_ action: Action, source: String) {
        onLog("Ação: \(action.rawValue) (\(source))")
        onAction(action)
    }

    nonisolated private static func name(of command: MPRemoteCommand, in center: MPRemoteCommandCenter) -> String {
        if command === center.togglePlayPauseCommand { return "play/pause" }
        if command === center.playCommand { return "play" }
        if command === center.pauseCommand { return "pause" }
        return "outro"
    }

    /// O iOS so entrega os comandos de midia ao app que esta "tocando" algo.
    /// Um loop de silencio mantem o app como dono dos controles.
    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV(seconds: 2))
            player.numberOfLoops = -1
            player.volume = 0.01
            player.play()
            keepAlive = player
        } catch {
            onLog("Não consegui iniciar o loop de silêncio: \(error.localizedDescription)")
        }
    }

    /// WAV PCM 16 bits mono de silencio.
    private static func silentWAV(seconds: Double, sampleRate: Int = 8000) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        let dataSize = samples * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: dataSize))
        return d
    }
}
