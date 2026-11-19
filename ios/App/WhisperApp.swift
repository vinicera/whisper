import SwiftUI

@main
struct WhisperApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var speech: SpeechService
    @StateObject private var orchestrator: Orchestrator

    init() {
        let settings = AppSettings()
        let speech = SpeechService()
        _settings = StateObject(wrappedValue: settings)
        _speech = StateObject(wrappedValue: speech)
        _orchestrator = StateObject(wrappedValue: Orchestrator(settings: settings, speech: speech))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(speech)
                .environmentObject(orchestrator)
        }
    }
}
