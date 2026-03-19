import AVFoundation

/// Owns AVAudioSession configuration and microphone permission for the entire app.
///
/// Call `requestPermissionAndConfigure()` once before starting AVAudioEngine.
/// The `.playAndRecord` category with `.mixWithOthers` lets Doki listen in the
/// background without killing music or other audio. The "Audio, AirPlay, and
/// Picture in Picture" background mode must be enabled in the Xcode target's
/// Signing & Capabilities tab for background detection to work.
final class AudioSessionManager {

    static let shared = AudioSessionManager()
    private init() {}

    // MARK: – Public interface

    enum PermissionError: Error {
        case denied
        case restricted
    }

    /// Requests microphone permission, then activates the audio session.
    /// Throws `PermissionError.denied` if the user has not granted access.
    func requestPermissionAndConfigure() async throws {
        guard await requestMicrophonePermission() else {
            throw PermissionError.denied
        }
        try configureSession()
    }

    /// Deactivates the session (call when the pipeline fully stops).
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: – Permission

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    // MARK: – Session configuration

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .playAndRecord — needed now for TTS playback; also keeps the session
        // alive for background wake-word detection when backgrounded.
        // .mixWithOthers — Doki doesn't duck or interrupt music; it just listens.
        // .allowBluetooth — allows AirPods / BT headsets as mic source.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )

        // Prefer 16 kHz to minimise conversion work in AudioCaptureEngine.
        // This is advisory; the hardware may override it.
        try session.setPreferredSampleRate(16_000)

        try session.setActive(true)
    }
}
