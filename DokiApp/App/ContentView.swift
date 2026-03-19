import SwiftUI

struct ContentView: View {
    @StateObject private var pipeline = VoicePipeline()

    var body: some View {
        Group {
            if pipeline.permissionDenied {
                PermissionDeniedView()
            } else {
                PipelineStatusView(state: pipeline.state)
            }
        }
        .overlay(ActivationIndicator(state: pipeline.state))
        .task {
            guard
                let picovoiceKey  = Bundle.main.infoDictionary?["PicovoiceAccessKey"]  as? String, !picovoiceKey.isEmpty,
                let deepgramKey   = Bundle.main.infoDictionary?["DeepgramAPIKey"]       as? String, !deepgramKey.isEmpty,
                let groqKey       = Bundle.main.infoDictionary?["GroqAPIKey"]           as? String, !groqKey.isEmpty,
                let elevenlabsKey = Bundle.main.infoDictionary?["ElevenLabsAPIKey"]     as? String, !elevenlabsKey.isEmpty
            else {
                print("[ContentView] Missing API key(s) in Info.plist — need PicovoiceAccessKey, DeepgramAPIKey, GroqAPIKey, ElevenLabsAPIKey")
                return
            }
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

// MARK: – Stage indicator

private struct PipelineStatusView: View {
    let state: PipelineState

    /// Drives the pulsing ring on `.capturing` and the rotation on `.processing`.
    @State private var animating = false

    var body: some View {
        VStack(spacing: 32) {
            Text("Doki")
                .font(.largeTitle.bold())

            ZStack {
                // Outer pulse ring — visible while capturing or speaking.
                Circle()
                    .stroke(state.color.opacity(0.25), lineWidth: 2)
                    .frame(width: 140, height: 140)
                    .scaleEffect(animating && (state == .capturing || state == .speaking) ? 1.18 : 1.0)

                // Filled backdrop.
                Circle()
                    .fill(state.color.opacity(0.12))
                    .frame(width: 110, height: 110)

                // Stage icon.
                Image(systemName: state.icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(state.color)
                    // Rotation spinner for "processing".
                    .rotationEffect(state == .processing ? .degrees(animating ? 360 : 0) : .zero)
            }
            .animation(
                state == .processing
                    ? .linear(duration: 1.6).repeatForever(autoreverses: false)
                    : (state == .capturing || state == .speaking)
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.3),
                value: animating
            )
            .onChange(of: state) { _, newState in
                // Reset then re-arm the animation each time the state changes.
                animating = false
                if newState != .idle {
                    withAnimation { animating = true }
                }
            }
            .onAppear {
                if state != .idle { animating = true }
            }

            Text(state.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: state.label)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: – Permission denied

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Microphone access denied")
                .font(.headline)
            Text("Open Settings → Doki → Microphone to enable it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
