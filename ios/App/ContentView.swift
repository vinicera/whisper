import Core
import SwiftUI

/// Fase 0: valida o pipeline (CI -> .ipa -> sideload) e o audio saindo nos oculos.
struct ContentView: View {
    @EnvironmentObject private var speech: SpeechService
    @State private var text = "Olá! O assistente de Cálculo está funcionando. A derivada de x^2 é 2x."
    @State private var route = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Teste de voz") {
                    TextEditor(text: $text)
                        .frame(minHeight: 100)
                        .accessibilityLabel("Texto para falar")
                    Button(speech.isSpeaking ? "Parar" : "Falar") {
                        speech.isSpeaking ? speech.stop() : speech.speak(text)
                    }
                    .font(.headline)
                    HStack {
                        Text("Velocidade")
                        Slider(value: $speech.rate, in: 0.35...0.6)
                    }
                }

                Section("O que o TTS recebe (sanitizado)") {
                    Text(SpeechSanitizer.sanitize(text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Saída de áudio") {
                    Text(route.isEmpty ? "Toque em Falar para ver a rota" : route)
                        .font(.footnote)
                    Button("Atualizar rota") { route = speech.currentRouteDescription }
                }
            }
            .navigationTitle("Whisper")
            .onChange(of: speech.isSpeaking) { _, _ in route = speech.currentRouteDescription }
        }
    }
}

#Preview {
    ContentView().environmentObject(SpeechService())
}
