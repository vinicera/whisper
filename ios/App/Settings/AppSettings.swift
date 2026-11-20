import Core
import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable {
    case auto, bridge, direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automático"
        case .bridge: return "Ponte (PC)"
        case .direct: return "Direto (Gemini)"
        }
    }
}

/// Preferencias: o que nao e segredo vai para UserDefaults; segredos vao para o Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var connection: ConnectionMode {
        didSet { defaults.set(connection.rawValue, forKey: "connection") }
    }
    @Published var solveMode: SolveMode {
        didSet { defaults.set(solveMode.rawValue, forKey: "solveMode") }
    }
    @Published var bridgeURL: String {
        didSet { defaults.set(bridgeURL, forKey: "bridgeURL") }
    }
    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: "geminiModel") }
    }
    /// Foto mais velha que isso e ignorada em "Resolver ultima foto" (0 = sem limite).
    @Published var maxPhotoAgeMinutes: Int {
        didSet { defaults.set(maxPhotoAgeMinutes, forKey: "maxPhotoAgeMinutes") }
    }
    @Published var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: "speechRate") }
    }
    /// Nivel de raciocinio do Gemini no Modo Direto ("" = padrao do modelo, mais lento).
    @Published var thinkingLevel: String {
        didSet { defaults.set(thinkingLevel, forKey: "thinkingLevel") }
    }
    @Published var bridgeToken: String {
        didSet { Keychain.set(bridgeToken, for: "bridgeToken") }
    }
    @Published var geminiKey: String {
        didSet { Keychain.set(geminiKey, for: "geminiKey") }
    }

    static let defaultGeminiModel = "gemini-3.8-flash"

    init() {
        connection = ConnectionMode(rawValue: defaults.string(forKey: "connection") ?? "") ?? .auto
        solveMode = SolveMode(rawValue: defaults.string(forKey: "solveMode") ?? "") ?? .tutor
        bridgeURL = defaults.string(forKey: "bridgeURL") ?? ""
        geminiModel = defaults.string(forKey: "geminiModel") ?? Self.defaultGeminiModel
        maxPhotoAgeMinutes = defaults.object(forKey: "maxPhotoAgeMinutes") as? Int ?? 10
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 0.5
        thinkingLevel = defaults.string(forKey: "thinkingLevel") ?? "low"
        bridgeToken = Keychain.get("bridgeToken")
        geminiKey = Keychain.get("geminiKey")
    }

    /// URL da ponte normalizada (aceita "100.64.0.1:8787" sem esquema).
    var bridgeBaseURL: URL? {
        var s = bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    var isBridgeConfigured: Bool { bridgeBaseURL != nil }
    var isDirectConfigured: Bool { !geminiKey.isEmpty }
}
