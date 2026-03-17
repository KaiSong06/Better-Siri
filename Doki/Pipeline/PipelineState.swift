enum PipelineState {
    /// Wake-word detector is running; mic in low-power listen mode.
    case idle
    /// Wake word triggered; actively capturing user speech.
    case capturing
    /// Audio shipped to STT/LLM; awaiting response.
    case processing
    /// TTS is playing back the response.
    case speaking

    var label: String {
        switch self {
        case .idle:       return "Listening for wake word…"
        case .capturing:  return "Capturing…"
        case .processing: return "Thinking…"
        case .speaking:   return "Speaking…"
        }
    }
}
