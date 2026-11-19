import Core
import Foundation

/// Modo Ponte: envia para o FastAPI no PC (que verifica com SymPy antes de responder).
struct BridgeProvider: SolveProvider {
    let baseURL: URL
    let token: String

    var label: String { "Ponte (PC)" }

    private func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Usado pelo modo Automatico: se nao responder rapido, cai para o Direto.
    func health(timeout: TimeInterval = 3) async -> HealthResponse? {
        guard let (data, resp) = try? await URLSession.shared.data(for: request("v1/health", timeout: timeout)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Contract.decoder.decode(HealthResponse.self, from: data)
    }

    func solve(_ image: EncodedImage, options: SolveOptions) async throws -> SolveResponse {
        let body = SolveRequest(
            client: ClientInfo(appVersion: AppInfo.version, device: AppInfo.deviceModel),
            image: ImagePayload(mime: image.mime, base64: image.base64, width: image.width, height: image.height,
                                capturedAt: AppInfo.iso8601(image.capturedAt), source: image.source),
            options: options)

        var req = request("v1/solve", timeout: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Contract.encoder.encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw ProviderError.http(401, "") }
        // Mesmo em erro (502, 422) o servidor manda um corpo com texto falavel.
        if let decoded = try? Contract.decoder.decode(SolveResponse.self, from: data) { return decoded }
        throw ProviderError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
    }
}
