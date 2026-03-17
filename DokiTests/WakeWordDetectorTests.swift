import XCTest
import AVFoundation
@testable import Doki

/// Integration test for the wake-word pipeline.
///
/// ## Requirements
/// - Must run on a **physical device** (mic unavailable on Simulator).
/// - Set `PICOVOICE_ACCESS_KEY` in the scheme's Run > Arguments > Environment Variables.
/// - `doki_ios.ppn` must be in the app bundle (same target membership as main app).
///
/// ## Running
/// Product → Test (⌘U), or individually via the test diamond in the gutter.
/// When the test is running, say "Doki" within 15 seconds.
final class WakeWordDetectorTests: XCTestCase {

    func testWakeWordLogsOnDetection() async throws {
        // Skip cleanly if no access key is configured in the scheme.
        guard let accessKey = ProcessInfo.processInfo.environment["PICOVOICE_ACCESS_KEY"],
              !accessKey.isEmpty else {
            throw XCTSkip("Set PICOVOICE_ACCESS_KEY in the scheme's environment variables.")
        }

        // Request mic permission. If already denied, fail with a clear message.
        let granted: Bool
        if #available(iOS 17, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    cont.resume(returning: $0)
                }
            }
        }
        guard granted else {
            XCTFail("Microphone permission denied. Grant access in Settings and re-run on device.")
            return
        }

        // Configure a minimal record-only session for the test.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .mixWithOthers)
        try session.setActive(true)
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        let capture  = AudioCaptureEngine()
        let detector = WakeWordDetector()

        try capture.start()
        try detector.start(accessKey: accessKey)

        let detected = expectation(description: "Wake word 'Doki' detected")
        detected.assertForOverFulfill = false

        let detectionTask = Task {
            for await frame in capture.audioFrames {
                if Task.isCancelled { break }
                let fired = (try? detector.process(frame: frame)) ?? false
                if fired {
                    print("[WakeWordDetectorTests] ✅ Wake word 'Doki' detected!")
                    detected.fulfill()
                }
            }
        }

        print("[WakeWordDetectorTests] 🎙 Say 'Doki' within 15 seconds…")
        await fulfillment(of: [detected], timeout: 15)

        detectionTask.cancel()
        detector.stop()
        capture.stop()
    }
}
