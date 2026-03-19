import SwiftUI

enum PipelineState: Equatable {
    /// Wake-word detector is running; mic in low-power listen mode.
    case idle
    /// Wake word triggered; actively capturing user speech.
    case capturing
    /// Audio shipped to STT + LLM; awaiting response.
    case processing
    /// TTS is playing back the response.
    case speaking

    var label: String {
        switch self {
        case .idle:       return "Listening for \"Hey Doki\"…"
        case .capturing:  return "Listening…"
        case .processing: return "Thinking…"
        case .speaking:   return "Speaking…"
        }
    }

    /// SF Symbol name for the current stage.
    var icon: String {
        switch self {
        case .idle:       return "waveform"
        case .capturing:  return "mic.fill"
        case .processing: return "brain"
        case .speaking:   return "speaker.wave.3.fill"
        }
    }

    /// Accent colour for the current stage.
    var color: Color {
        switch self {
        case .idle:       return .secondary
        case .capturing:  return .red
        case .processing: return .orange
        case .speaking:   return .blue
        }
    }
}
