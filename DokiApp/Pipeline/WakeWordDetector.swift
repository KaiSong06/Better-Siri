import Foundation
import Porcupine

/// Wraps the Porcupine wake-word engine for the custom "Doki" keyword.
///
/// ## Setup
/// 1. Go to console.picovoice.ai and train a custom wake word named "Doki".
/// 2. Download the iOS model file (`doki_ios.ppn`) and add it to the Xcode
///    target so it's included in the app bundle.
/// 3. Your free Picovoice access key is at console.picovoice.ai → Profile.
///
/// ## Threading
/// `process(frame:)` must always be called from the same non-main thread.
/// Porcupine is not thread-safe across concurrent callers; the pipeline loop
/// in `AudioPipeline` guarantees single-threaded access.
final class WakeWordDetector {

    private var porcupine: Porcupine?

    // MARK: – Lifecycle

    /// Loads the "doki_ios.ppn" model from the app bundle and starts the engine.
    func start(accessKey: String) throws {
        guard let keywordPath = Bundle.main.path(forResource: "doki_ios", ofType: "ppn") else {
            throw WakeWordError.modelFileNotFound(
                "Add doki_ios.ppn to the Xcode target. Download from console.picovoice.ai."
            )
        }

        porcupine = try Porcupine(accessKey: accessKey, keywordPath: keywordPath)
    }

    func stop() {
        porcupine?.delete()
        porcupine = nil
    }

    // MARK: – Frame processing

    /// Feed one 512-sample Int16 frame at 16 kHz mono.
    /// Returns `true` when "Doki" is detected. Must not be called after `stop()`.
    func process(frame: [Int16]) throws -> Bool {
        guard let porcupine else { return false }
        let keywordIndex = try porcupine.process(pcm: frame)
        return keywordIndex >= 0
    }
}

enum WakeWordError: Error, LocalizedError {
    case modelFileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelFileNotFound(let message): return "Wake word model not found: \(message)"
        }
    }
}
