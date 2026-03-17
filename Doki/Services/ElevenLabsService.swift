import AVFoundation
import Foundation

/// Synthesises text via ElevenLabs and plays the audio back through AVAudioPlayer.
///
/// ## Lifecycle per utterance
/// ```swift
/// try await elevenlabs.speak("Hello, how can I help?")
/// // Returns when playback finishes (or on error / cancellation).
/// ```
///
/// ## Wake-word blocking
/// `speak()` is called from inside the pipeline loop body. The loop suspends
/// for the full fetch + playback duration, so Porcupine receives no frames —
/// wake-word detection is blocked without any extra mechanism.
///
/// ## Silent fallback
/// If the ElevenLabs request fails or the audio can't be decoded, `speak()`
/// throws. `AudioPipeline` catches the error, logs it, and returns the pipeline
/// to `.idle`. No audio plays, but the app keeps running.
///
/// ## Threading
/// `@MainActor` keeps AVAudioPlayer on the main run loop (required for its
/// internal timer and delegate callbacks). `AudioPipeline` calls `speak()` with
/// `await`, which hops to the main actor; the actor is released at every async
/// suspension point so UI updates are never blocked.
@MainActor
final class ElevenLabsService {

    // MARK: – Configuration

    private static let apiHost  = "api.elevenlabs.io"
    /// eleven_turbo_v2_5 is ElevenLabs' fastest model — recommended for real-time voice.
    private static let model    = "eleven_turbo_v2_5"

    // MARK: – Errors

    enum TTSError: Error, LocalizedError {
        case httpError(Int, String)
        case playbackInterrupted
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                return "ElevenLabs HTTP \(code): \(body.prefix(200))"
            case .playbackInterrupted:
                return "Audio playback was interrupted"
            case .decodingFailed:
                return "AVAudioPlayer could not decode the received audio"
            }
        }
    }

    // MARK: – State

    private let apiKey:  String
    private let voiceID: String
    private let session  = URLSession(configuration: .default)

    /// Retained for the duration of playback; nil otherwise.
    private var coordinator: PlaybackCoordinator?

    // MARK: – Init

    /// - Parameters:
    ///   - apiKey:  Your ElevenLabs API key (from elevenlabs.io → Profile → API Keys).
    ///   - voiceID: ElevenLabs voice identifier. Defaults to "Rachel" (21m00Tcm4TlvDq8ikWAM).
    ///              Find IDs at elevenlabs.io/voice-library or via GET /v1/voices.
    init(apiKey: String, voiceID: String = "21m00Tcm4TlvDq8ikWAM") {
        self.apiKey  = apiKey
        self.voiceID = voiceID
    }

    // MARK: – Public API

    /// Fetches synthesised audio from ElevenLabs and plays it to completion.
    ///
    /// Suspends the caller for the full network round-trip plus playback duration.
    /// Throws on network errors, HTTP errors, or audio decoding failures.
    /// Callers should treat all errors as non-fatal and fall through to idle.
    func speak(_ text: String) async throws {
        try Task.checkCancellation()
        let audioData = try await fetchAudio(text: text)
        try Task.checkCancellation()
        try await playback(data: audioData)
    }

    /// Stops any in-progress playback immediately.
    /// Safe to call when nothing is playing. Called by `AudioPipeline.stop()`.
    func stopPlayback() {
        coordinator?.stop()
        coordinator = nil
    }

    // MARK: – Network

    private func fetchAudio(text: String) async throws -> Data {
        var components      = URLComponents()
        components.scheme   = "https"
        components.host     = Self.apiHost
        components.path     = "/v1/text-to-speech/\(voiceID)"

        guard let url = components.url else {
            preconditionFailure("[ElevenLabsService] Failed to build URL")
        }

        var request             = URLRequest(url: url)
        request.httpMethod      = "POST"
        request.timeoutInterval = 20
        // ElevenLabs authentication header (not Bearer).
        request.setValue(apiKey,            forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Request MP3 — AVAudioPlayer decodes it natively, no temp file needed.
        request.setValue("audio/mpeg",       forHTTPHeaderField: "Accept")

        let body = TTSRequest(
            text:          text,
            modelId:       Self.model,
            voiceSettings: .default
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)

        guard let http = urlResponse as? HTTPURLResponse else {
            throw TTSError.httpError(0, "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw TTSError.httpError(http.statusCode, body)
        }

        return data
    }

    // MARK: – Playback

    private func playback(data: Data) async throws {
        // withCheckedThrowingContinuation suspends until the coordinator calls
        // resume() — either on natural playback end or via stopPlayback().
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume()
                return
            }
            let coord = PlaybackCoordinator(continuation: continuation)
            self.coordinator = coord
            do {
                try coord.start(data: data)
            } catch {
                self.coordinator = nil
                continuation.resume(throwing: error)
            }
        }
        coordinator = nil
    }
}

// MARK: – Playback coordinator

/// Bridges AVAudioPlayerDelegate callbacks to a CheckedContinuation.
/// Retained by ElevenLabsService for exactly the duration of one playback.
@MainActor
private final class PlaybackCoordinator: NSObject, AVAudioPlayerDelegate {

    private var player:       AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        super.init()
    }

    func start(data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        player.play()
    }

    /// Stops playback early (e.g. on pipeline stop). Resumes the continuation
    /// successfully so the caller unblocks without an error being thrown.
    func stop() {
        player?.stop()
        finish()
    }

    // MARK: – AVAudioPlayerDelegate

    // Delegate callbacks arrive on the main thread from ObjC — `nonisolated`
    // is required. We hop back to `@MainActor` via Task to call `finish()`.

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if flag {
                self?.finish()
            } else {
                self?.finish(throwing: ElevenLabsService.TTSError.playbackInterrupted)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finish(throwing: error ?? ElevenLabsService.TTSError.decodingFailed)
        }
    }

    // MARK: – Private

    private func finish(throwing error: Error? = nil) {
        // Guard prevents double-resume if stop() and a delegate callback race.
        guard let cont = continuation else { return }
        continuation = nil
        player       = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}

// MARK: – Codable request model

private struct TTSRequest: Encodable {
    let text:          String
    let modelId:       String
    let voiceSettings: VoiceSettings

    struct VoiceSettings: Encodable {
        let stability:       Double
        let similarityBoost: Double

        /// Balanced defaults: stable enough for a voice assistant, natural enough
        /// not to sound robotic.
        static let `default` = VoiceSettings(stability: 0.5, similarityBoost: 0.75)

        enum CodingKeys: String, CodingKey {
            case stability
            case similarityBoost = "similarity_boost"
        }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case modelId       = "model_id"
        case voiceSettings = "voice_settings"
    }
}
