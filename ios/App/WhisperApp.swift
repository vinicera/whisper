import SwiftUI

@main
struct WhisperApp: App {
    @StateObject private var speech = SpeechService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speech)
        }
    }
}
