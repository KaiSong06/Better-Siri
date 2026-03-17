import Foundation

/// Collects speech frames after a wake-word trigger and stops on silence or timeout.
///
/// ## Design
/// This is a *synchronous state machine* — no internal concurrency. The pipeline
/// loop in `AudioPipeline` calls `process(frame:)` once per 512-sample frame
/// (32 ms at 16 kHz) on its own background thread. No locks needed.
///
/// ## Silence detection
/// Uses RMS energy in dBFS. Detection only activates after `minSpeechOnsetFrames`
/// consecutive loud frames, so brief pops or the tail of "Doki" don't trigger
/// an immediate stop. Once onset is confirmed, `silenceCutoffFrames` of quiet
/// ends the session.
///
/// ## Output format
/// Raw **Linear16 PCM**: Int16 little-endian, 16 kHz, mono.
/// This is the exact encoding Deepgram's streaming WebSocket API expects.
final class SpeechCaptureSession {

    // MARK: – Tunable parameters

    /// Energy below this level (dBFS) is silence. Raise toward -30 in noisy environments.
    static let silenceThresholdDB: Float = -40.0

    /// Consecutive loud frames required before silence detection activates (~96 ms).
    /// Prevents the wake-word tail or a mic click from immediately ending the session.
    static let minSpeechOnsetFrames: Int = 3

    /// Consecutive silent frames that end the session (~1.5 s at 32 ms/frame).
    static let silenceCutoffFrames: Int = 47

    /// Hard stop regardless of speech (~10 s at 32 ms/frame).
    static let maxFrames: Int = 312

    // MARK: – Result types

    enum FrameResult {
        /// A 1 024-byte chunk (512 × Int16) ready to forward over the Deepgram WebSocket.
        case streaming(Data)
        /// Capture ended. `audio` is the complete recording; use for logging/storage.
        /// Streaming chunks already contain all the same audio — no need to re-send.
        case complete(Data, StopReason)
    }

    enum StopReason: CustomStringConvertible {
        case silenceDetected
        case timeout

        var description: String {
            switch self {
            case .silenceDetected: return "silence"
            case .timeout:         return "timeout"
            }
        }
    }

    // MARK: – State

    private var allSamples: [Int16] = []
    private var totalFrameCount:   Int  = 0
    private var speechFrameCount:  Int  = 0   // consecutive frames above threshold
    private var silenceFrameCount: Int  = 0   // consecutive frames below threshold after onset
    private var hasDetectedOnset:  Bool = false

    init() {
        // Pre-allocate for the full 10-second maximum to avoid repeated resizing.
        allSamples.reserveCapacity(Self.maxFrames * 512)
    }

    // MARK: – Frame processing

    /// Feed one 512-sample Int16 frame (32 ms at 16 kHz). Call once per frame from
    /// the pipeline loop — never concurrently.
    func process(frame: [Int16]) -> FrameResult {
        totalFrameCount += 1
        allSamples.append(contentsOf: frame)

        updateSilenceTracking(for: frame)

        if hasDetectedOnset && silenceFrameCount >= Self.silenceCutoffFrames {
            return .complete(fullPCM(), .silenceDetected)
        }
        if totalFrameCount >= Self.maxFrames {
            return .complete(fullPCM(), .timeout)
        }

        return .streaming(frame.pcmData())
    }

    // MARK: – Diagnostics

    /// Duration of audio collected so far, in seconds.
    var durationSeconds: Double {
        Double(totalFrameCount) * 512.0 / 16_000.0
    }

    // MARK: – Private helpers

    private func updateSilenceTracking(for frame: [Int16]) {
        let db = rmsDB(frame)
        if db < Self.silenceThresholdDB {
            // Silent frame
            speechFrameCount = 0
            if hasDetectedOnset { silenceFrameCount += 1 }
        } else {
            // Loud frame
            silenceFrameCount = 0
            speechFrameCount += 1
            if speechFrameCount >= Self.minSpeechOnsetFrames {
                hasDetectedOnset = true
            }
        }
    }

    /// RMS energy of the frame in dBFS (0 dBFS = full-scale Int16 ±32 767).
    private func rmsDB(_ frame: [Int16]) -> Float {
        guard !frame.isEmpty else { return -160 }
        var sumSq: Float = 0
        for s in frame { sumSq += Float(s) * Float(s) }
        let rms = sqrtf(sumSq / Float(frame.count))
        guard rms > 0 else { return -160 }
        return 20 * log10f(rms / 32_767.0)
    }

    /// All accumulated samples as raw Linear16 PCM `Data`.
    private func fullPCM() -> Data {
        allSamples.pcmData()
    }
}

// MARK: – Array<Int16> → Data

private extension Array where Element == Int16 {
    /// Reinterprets the Int16 array as raw bytes (little-endian on all Apple silicon / x86).
    func pcmData() -> Data {
        withUnsafeBytes { Data($0) }
    }
}
