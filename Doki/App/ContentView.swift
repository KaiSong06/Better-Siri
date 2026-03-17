import SwiftUI

struct ContentView: View {
    @StateObject private var pipeline = AudioPipeline()

    var body: some View {
        VStack(spacing: 16) {
            Text("Doki")
                .font(.largeTitle.bold())

            if pipeline.permissionDenied {
                Label("Microphone access denied", systemImage: "mic.slash")
                    .foregroundStyle(.red)
                Text("Enable microphone access in Settings → Doki.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text(pipeline.state.label)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut, value: pipeline.state.label)
            }
        }
        .task {
            guard
                let picovoiceKey  = Bundle.main.infoDictionary?["PicovoiceAccessKey"]  as? String, !picovoiceKey.isEmpty,
                let deepgramKey   = Bundle.main.infoDictionary?["DeepgramAPIKey"]       as? String, !deepgramKey.isEmpty,
                let groqKey       = Bundle.main.infoDictionary?["GroqAPIKey"]           as? String, !groqKey.isEmpty,
                let elevenlabsKey = Bundle.main.infoDictionary?["ElevenLabsAPIKey"]     as? String, !elevenlabsKey.isEmpty
            else {
                print("[ContentView] Missing API key(s) — need PicovoiceAccessKey, DeepgramAPIKey, GroqAPIKey, ElevenLabsAPIKey in Info.plist")
                return
            }
            // Optional: override the default voice with Info.plist key "ElevenLabsVoiceID"
            let voiceID = Bundle.main.infoDictionary?["ElevenLabsVoiceID"] as? String
                       ?? "21m00Tcm4TlvDq8ikWAM"

            await pipeline.start(
                picovoiceKey:  picovoiceKey,
                deepgramKey:   deepgramKey,
                groqKey:       groqKey,
                elevenlabsKey: elevenlabsKey,
                voiceID:       voiceID
            )
        }
        .onDisappear {
            pipeline.stop()
        }
    }
}
