import Core
import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var orchestrator: Orchestrator

    @State private var showCamera = false
    @State private var showSettings = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                actionsSection
                playbackSection
                if let response = orchestrator.lastResponse {
                    answerSection(response)
                }
            }
            .navigationTitle("Whisper")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { DebugLogView() } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("Registro de depuração")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Configurações")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in orchestrator.solve(image: image, source: .camera) }
                    .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        orchestrator.solve(image: image, source: .upload)
                    } else {
                        orchestrator.log("Não consegui abrir a foto escolhida")
                    }
                    pickerItem = nil
                }
            }
        }
    }

    // MARK: - Secoes

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    if let since = orchestrator.workingSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(since))) s · \(statusSubtitle)")
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else {
                        Text(statusSubtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if orchestrator.isBusy {
                    Button("Cancelar", role: .cancel) { orchestrator.cancel() }
                        .buttonStyle(.bordered)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch orchestrator.phase {
        case .working: ProgressView()
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: speech.isSpeaking ? "speaker.wave.2.fill" : "checkmark.circle")
                .foregroundStyle(speech.isSpeaking ? Color.accentColor : .secondary)
        }
    }

    private var statusTitle: String {
        switch orchestrator.phase {
        case .working(let step): return step
        case .failed: return "Algo deu errado"
        case .idle: return speech.isSpeaking ? "Falando" : "Pronto"
        }
    }

    private var statusSubtitle: String {
        if case .failed(let message) = orchestrator.phase { return message }
        return "Conexão: \(settings.connection.label) · Modo: \(settings.solveMode.label)"
    }

    private var actionsSection: some View {
        Section("Resolver") {
            Button { orchestrator.solveLatestPhoto() } label: {
                Label("Resolver última foto", systemImage: "photo.on.rectangle.angled")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .disabled(orchestrator.isBusy)

            Button { showCamera = true } label: { Label("Fotografar com o iPhone", systemImage: "camera") }
                .disabled(!CameraPicker.isAvailable || orchestrator.isBusy)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Escolher da galeria", systemImage: "photo")
            }
            .disabled(orchestrator.isBusy)

            Picker("Modo", selection: $settings.solveMode) {
                ForEach(SolveMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var playbackSection: some View {
        Section("Fala") {
            HStack {
                controlButton("backward.fill", "Passo anterior") { speech.previous() }
                controlButton("arrow.counterclockwise", "Repetir passo") { speech.repeatCurrent() }
                controlButton(speech.isSpeaking ? "stop.fill" : "play.fill",
                              speech.isSpeaking ? "Parar" : "Falar de novo") {
                    speech.isSpeaking ? speech.stop() : speech.speak(segments: speech.segments)
                }
                controlButton("forward.fill", "Próximo passo") { speech.next() }
            }
            .disabled(speech.segments.isEmpty)
        }
    }

    private func controlButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func answerSection(_ response: SolveResponse) -> some View {
        Section {
            ForEach(Array(speech.segments.enumerated()), id: \.offset) { index, segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.kind.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .fontWeight(index == speech.currentIndex && speech.isSpeaking ? .semibold : .regular)
                }
                .listRowBackground(index == speech.currentIndex && speech.isSpeaking
                                   ? Color.accentColor.opacity(0.12) : nil)
                .onTapGesture { speech.speak(segments: speech.segments, from: index) }
            }
        } header: {
            Text("Resposta")
        } footer: {
            Text(verificationText(response))
        }
    }

    private func verificationText(_ r: SolveResponse) -> String {
        let source = orchestrator.lastProviderLabel
        switch r.verification.passed {
        case .some(true): return "\(source) · conferido pelo SymPy ✓"
        case .some(false): return "\(source) · o SymPy NÃO confirmou o resultado"
        case .none: return "\(source) · \(r.verification.notes ?? "sem verificação")"
        }
    }
}

extension SolveMode {
    var label: String {
        switch self {
        case .tutor: return "Tutor"
        case .resposta: return "Resposta"
        case .ditado: return "Ditado"
        }
    }
}
