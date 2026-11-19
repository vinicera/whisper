import SwiftUI

/// Registro na tela: substitui o console do Xcode, que nao temos no Windows.
struct DebugLogView: View {
    @EnvironmentObject private var orchestrator: Orchestrator
    @EnvironmentObject private var speech: SpeechService

    var body: some View {
        List {
            Section("Áudio") {
                Text(speech.currentRouteDescription).font(.footnote)
            }
            Section("Eventos") {
                if orchestrator.logs.isEmpty {
                    Text("Nada ainda.").foregroundStyle(.secondary)
                }
                ForEach(orchestrator.logs) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(entry.text).font(.footnote).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Registro")
        .navigationBarTitleDisplayMode(.inline)
    }
}
