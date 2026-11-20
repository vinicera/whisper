import Core
import Foundation

typealias SegmentHandler = @MainActor (SpeechSegment) -> Void

protocol SolveProvider {
    var label: String { get }
    func solve(_ image: EncodedImage, options: SolveOptions) async throws -> SolveResponse
    /// Versao com streaming: chama `onSegment` a cada trecho falado pronto, antes do fim.
    func solve(_ image: EncodedImage, options: SolveOptions,
               onSegment: @escaping SegmentHandler) async throws -> SolveResponse
}

extension SolveProvider {
    /// Provedores sem streaming (ex.: ponte) entregam tudo no fim.
    func solve(_ image: EncodedImage, options: SolveOptions,
               onSegment: @escaping SegmentHandler) async throws -> SolveResponse {
        try await solve(image, options: options)
    }
}

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .http(401, _): return "O token da ponte está errado. Confira nas configurações."
        case .http(429, _): return "Limite de uso da inteligência artificial atingido. Tente daqui a pouco."
        case .http(let code, _) where (500...504).contains(code):
            return "O Gemini está sobrecarregado agora, do lado do Google. Tente de novo em alguns minutos."
        case .http(let code, let msg): return "O servidor respondeu com erro \(code). \(msg)"
        case .badResponse(let msg): return "Resposta inválida da inteligência artificial. \(msg)"
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func iso8601(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}
