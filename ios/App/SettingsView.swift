import Core
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var orchestrator: Orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var bridgeStatus = ""
    @State private var testingBridge = false
    @State private var voiceTest = "A derivada de x^2 é 2x. Se você ouviu isto nos óculos, o áudio está funcionando."
    @State private var route = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Conexão", selection: $settings.connection) {
                        ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Automático: usa o PC se ele responder em 3 segundos; senão, o Gemini direto.")
                }

                Section {
                    TextField("http://100.x.x.x:8787", text: $settings.bridgeURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token (BRIDGE_TOKEN do .env)", text: $settings.bridgeToken)
                        .textInputAutocapitalization(.never)
                    Button {
                        testingBridge = true
                        Task {
                            bridgeStatus = await orchestrator.testBridge()
                            testingBridge = false
                        }
                    } label: {
                        HStack {
                            Text("Testar conexão com o PC")
                            if testingBridge { Spacer(); ProgressView() }
                        }
                    }
                    if !bridgeStatus.isEmpty {
                        Text(bridgeStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Ponte (servidor no PC)")
                } footer: {
                    Text("Use o IP do Tailscale do PC (começa com 100.) ou o endereço https do tailscale serve.")
                }

                Section {
                    SecureField("Chave da API (aistudio.google.com)", text: $settings.geminiKey)
                        .textInputAutocapitalization(.never)
                    TextField("Modelo", text: $settings.geminiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if settings.geminiModel != AppSettings.defaultGeminiModel {
                        Button("Voltar ao padrão (\(AppSettings.defaultGeminiModel))") {
                            settings.geminiModel = AppSettings.defaultGeminiModel
                        }
                    }
                    Picker("Raciocínio", selection: $settings.thinkingLevel) {
                        Text("Mínimo").tag("minimal")
                        Text("Rápido").tag("low")
                        Text("Caprichado").tag("high")
                        Text("Padrão do modelo").tag("")
                    }
                } header: {
                    Text("Gemini direto")
                } footer: {
                    Text("A chave fica guardada no Keychain do iPhone. Rápido responde bem mais cedo; "
                        + "Caprichado pensa mais em questões difíceis.")
                }

                Section("Foto") {
                    Stepper(value: $settings.maxPhotoAgeMinutes, in: 0...120, step: 5) {
                        Text(settings.maxPhotoAgeMinutes == 0
                             ? "Usar a última foto de qualquer data"
                             : "Ignorar fotos com mais de \(settings.maxPhotoAgeMinutes) min")
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $settings.speechRate, in: 0.30...0.55)
                        Image(systemName: "hare")
                    }
                    .accessibilityLabel("Velocidade da fala")
                    TextField("Texto de teste", text: $voiceTest, axis: .vertical)
                    Button("Testar voz") {
                        speech.speechRateSync(settings.speechRate)
                        speech.announce(voiceTest)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { route = speech.currentRouteDescription }
                    }
                    if !route.isEmpty {
                        Text("Saída: \(route)").font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Voz em uso", value: SpeechService.bestVoiceDescription)
                } header: {
                    Text("Voz")
                } footer: {
                    Text("Para uma voz bem menos robótica: Ajustes do iPhone → Acessibilidade → Conteúdo Falado → "
                        + "Vozes → Português (Brasil), e baixe uma voz \"Aprimorada\" ou \"Premium\". "
                        + "O app passa a usá-la sozinho.")
                }

                Section {
                    LabeledContent("1 toque", value: "pausa / continua")
                    LabeledContent("2 toques", value: "repete o trecho")
                    LabeledContent("3 toques", value: "volta um trecho")
                    LabeledContent("4 toques", value: "vai para a resposta")
                } header: {
                    Text("Toques nos óculos")
                } footer: {
                    Text("Cada parte é anunciada (\"Passo dois de cinco\") e a resposta final é repetida devagar "
                        + "no fim. Os toques recebidos aparecem no Registro, para conferir se os óculos estão "
                        + "mandando os comandos.")
                }

                Section("Sobre") {
                    LabeledContent("Versão", value: AppInfo.version)
                    LabeledContent("Aparelho", value: AppInfo.deviceModel)
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}
