import Foundation

// Espelho de server/app/models.py (fonte da verdade: shared/contract/*.schema.json).
// As chaves JSON sao snake_case; os encoders abaixo fazem a conversao.

public enum Contract {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

// MARK: - App -> Servidor

public enum SolveMode: String, Codable, CaseIterable, Sendable {
    case tutor, resposta, ditado
}

public enum SolveDetail: String, Codable, Sendable {
    case resumo
    case passoAPasso = "passo_a_passo"
}

public enum ImageSourceKind: String, Codable, Sendable {
    case photoLibrary = "photo_library"
    case camera
    case glassesSdk = "glasses_sdk"
    case upload
}

public struct ClientInfo: Codable, Sendable {
    public var appVersion: String
    public var device: String
    public var locale: String

    public init(appVersion: String, device: String, locale: String = "pt-BR") {
        self.appVersion = appVersion
        self.device = device
        self.locale = locale
    }
}

public struct ImagePayload: Codable, Sendable {
    public var mime: String
    public var base64: String
    public var width: Int?
    public var height: Int?
    public var capturedAt: String?
    public var source: ImageSourceKind

    public init(mime: String = "image/jpeg", base64: String, width: Int? = nil, height: Int? = nil,
                capturedAt: String? = nil, source: ImageSourceKind) {
        self.mime = mime
        self.base64 = base64
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.source = source
    }
}

public struct SolveOptions: Codable, Sendable {
    public var mode: SolveMode
    public var detail: SolveDetail
    public var questionHint: String?
    public var verify: Bool
    public var maxSpeechSeconds: Int

    public init(mode: SolveMode = .tutor, detail: SolveDetail = .passoAPasso, questionHint: String? = nil,
                verify: Bool = true, maxSpeechSeconds: Int = 120) {
        self.mode = mode
        self.detail = detail
        self.questionHint = questionHint
        self.verify = verify
        self.maxSpeechSeconds = maxSpeechSeconds
    }
}

public struct SolveRequest: Codable, Sendable {
    public var requestId: String
    public var client: ClientInfo
    public var image: ImagePayload
    public var options: SolveOptions

    public init(requestId: String = UUID().uuidString, client: ClientInfo, image: ImagePayload,
                options: SolveOptions = SolveOptions()) {
        self.requestId = requestId
        self.client = client
        self.image = image
        self.options = options
    }
}

// MARK: - Servidor -> App

public enum SolveStatus: String, Codable, Sendable {
    case ok, partial, unreadable, error
}

public struct SpeechSegment: Codable, Sendable, Identifiable {
    public var id: Int
    public var kind: String  // aviso | enunciado | plano | passo | resposta
    public var text: String

    public init(id: Int, kind: String, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public struct Speech: Codable, Sendable {
    public var fullText: String
    public var segments: [SpeechSegment]
    public var lang: String
    public var estimatedSeconds: Int

    public init(fullText: String, segments: [SpeechSegment], lang: String = "pt-BR", estimatedSeconds: Int? = nil) {
        self.fullText = fullText
        self.segments = segments
        self.lang = lang
        // ~150 palavras por minuto
        self.estimatedSeconds = estimatedSeconds ?? max(1, fullText.split(separator: " ").count * 2 / 5)
    }
}

public struct Verification: Codable, Sendable {
    public var performed: Bool
    public var passed: Bool?
    public var engine: String
    public var notes: String?

    public init(performed: Bool, passed: Bool? = nil, engine: String = "sympy", notes: String? = nil) {
        self.performed = performed
        self.passed = passed
        self.engine = engine
        self.notes = notes
    }
}

public struct ErrorInfo: Codable, Sendable {
    public var code: String
    public var retryable: Bool
    public var message: String?

    public init(code: String, retryable: Bool, message: String? = nil) {
        self.code = code
        self.retryable = retryable
        self.message = message
    }
}

public struct SolveResponse: Codable, Sendable {
    public var requestId: String
    public var status: SolveStatus
    public var speech: Speech
    public var verification: Verification
    public var error: ErrorInfo?
    /// Folha com varias questoes: rotulos na ordem de leitura (vazio/nil = questao unica).
    public var questoes: [String]?
    /// Posicao (1 = primeira) da questao resolvida em `questoes`.
    public var questaoAtual: Int?

    public init(requestId: String, status: SolveStatus, speech: Speech, verification: Verification,
                error: ErrorInfo? = nil, questoes: [String]? = nil, questaoAtual: Int? = nil) {
        self.requestId = requestId
        self.status = status
        self.speech = speech
        self.verification = verification
        self.error = error
        self.questoes = questoes
        self.questaoAtual = questaoAtual
    }
}

public struct HealthResponse: Codable, Sendable {
    public var status: String
    public var version: String
    public var llmProvider: String
    public var model: String
}
