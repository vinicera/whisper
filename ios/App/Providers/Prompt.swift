import Core
import Foundation

/// O system prompt e o MESMO arquivo do servidor (server/app/prompts/system_pt.md),
/// copiado para o bundle pelo project.yml. Uma unica fonte da verdade.
enum Prompt {
    static let system: String = {
        if let url = Bundle.main.url(forResource: "system_pt", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return """
        Você é um professor de Cálculo ditando a resolução em voz alta. Nos campos falados, \
        escreva tudo por extenso, sem nenhum símbolo matemático, e responda no JSON pedido.
        """
    }()

    /// Igual a build_user_message em server/app/llm.py.
    static func userMessage(_ options: SolveOptions) -> String {
        [
            "Modo: \(options.mode.rawValue)",
            "Detalhe: \(options.detail.rawValue)",
            "Questão indicada: \(options.questionHint ?? "nenhuma")",
            "Duração máxima da fala: \(options.maxSpeechSeconds) segundos.",
            "Responda somente com o JSON no esquema fornecido.",
        ].joined(separator: "\n")
    }
}

/// Esquema de resposta no formato do Gemini (subconjunto OpenAPI), espelho de ModelAnswer.
enum GeminiSchema {
    private static let string: [String: Any] = ["type": "STRING"]
    private static let optionalString: [String: Any] = ["type": "STRING", "nullable": true]

    static let modelAnswer: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "legivel": ["type": "BOOLEAN"],
            "motivo_ilegivel_falado": optionalString,
            "enunciado_latex": string,
            "enunciado_falado": string,
            "tipo": ["type": "STRING", "enum": [
                "derivada", "integral_indefinida", "integral_definida", "limite",
                "serie", "edo", "equacao", "outro",
            ]] as [String: Any],
            "plano_falado": string,
            "sympy": [
                "type": "OBJECT",
                "nullable": true,
                "properties": [
                    "expr": string,
                    "var": string,
                    "operacao": ["type": "STRING", "enum": [
                        "derivar", "integrar_indefinida", "integrar_definida", "limite",
                        "resolver", "simplificar", "nenhuma",
                    ]] as [String: Any],
                    "ordem": ["type": "INTEGER", "nullable": true] as [String: Any],
                    "inferior": optionalString,
                    "superior": optionalString,
                    "tende_a": optionalString,
                    "lado": optionalString,
                    "resultado": string,
                ] as [String: Any],
                "required": ["expr", "operacao", "resultado"],
            ] as [String: Any],
            "passos": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": ["falado": string, "latex": string],
                    "required": ["falado"],
                ] as [String: Any],
            ] as [String: Any],
            "resposta_falada": string,
            "resposta_latex": string,
        ] as [String: Any],
        "required": ["legivel", "enunciado_falado", "resposta_falada"],
        "propertyOrdering": [
            "legivel", "motivo_ilegivel_falado", "enunciado_latex", "enunciado_falado", "tipo",
            "plano_falado", "sympy", "passos", "resposta_falada", "resposta_latex",
        ],
    ]
}
