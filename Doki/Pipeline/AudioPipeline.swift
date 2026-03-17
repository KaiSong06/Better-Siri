import Foundation

/// Orchestrates the full pipeline: wake word → capture → STT → LLM → TTS.
///
/// ## Threading model
/// - `start()` / `stop()` and all `@Published` mutations run on the MainActor.
/// - The pipeline loop runs in a `Task.detached` (off main thread) so audio
///   frame processing and network calls never block the UI.
///
/// ## Run-loop modes
///
///   IDLE       — frames fed to WakeWordDetector (Porcupine)
///                ↓ wake word fires → connect Deepgram socket
///   CAPTURING  — frames streamed to DeepgramService
///                ↓ silence / 10 s timeout
///   PROCESSING — Deepgram.finalise() → GroqService.complete()
///                ↓ response ready
///   SPEAKING   — ElevenLabsService.speak() — loop suspended here
///                Wake-word detection is blocked for the full playback duration
///                because the `for await frame` loop cannot iterate while
///                speak() is awaited.
///                ↓ playback finishes (or silent fallback on error)
///   IDLE
@MainActor
final class AudioPipeline: ObservableObject {

    @Published private(set) var state: PipelineState = .idle
    @Published private(set) var permissionDenied = false

    private let wakeWord = WakeWordDetector()
    private let capture  = AudioCaptureEngine()

    private var pipelineTask:     Task<Void, Never>?
    private var deepgramService:  DeepgramService?
    private var groqService:      GroqService?
    private var elevenlabsService: ElevenLabsService?
    private var memoryStore:      MemoryStore?
    private var sessionID:        String = ""
    private var memorySummary:    String = ""

    // MARK: – Lifecycle

    func start(
        picovoiceKey:  String,
        deepgramKey:   String,
        groqKey:       String,
        elevenlabsKey: String,
        voiceID:       String = "21m00Tcm4TlvDq8ikWAM"
    ) async {
        do {
            try await AudioSessionManager.shared.requestPermissionAndConfigure()
        } catch AudioSessionManager.PermissionError.denied {
            permissionDenied = true
            return
        } catch {
            print("[AudioPipeline] AVAudioSession error: \(error)")
            return
        }

        do {
            try capture.start()
            try wakeWord.start(accessKey: picovoiceKey)
        } catch {
            print("[AudioPipeline] Failed to start pipeline stages: \(error)")
            return
        }

        let deepgram   = DeepgramService(apiKey: deepgramKey)
        let groq       = GroqService(apiKey: groqKey)
        let elevenlabs = ElevenLabsService(apiKey: elevenlabsKey, voiceID: voiceID)
        deepgramService   = deepgram
        groqService       = groq
        elevenlabsService = elevenlabs

        // Initialise memory. Non-fatal — app works without persistence if this fails.
        sessionID     = UUID().uuidString
        memorySummary = ""
        do {
            let store     = try MemoryStore()
            memorySummary = (try? await store.buildMemorySummary()) ?? ""
            memoryStore   = store
        } catch {
            print("[AudioPipeline] MemoryStore init failed (non-fatal): \(error)")
        }

        let audioFrames    = capture.audioFrames
        let detector       = wakeWord
        let store          = memoryStore
        let sid            = sessionID
        let memSummary     = memorySummary

        pipelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop(
                audioFrames:   audioFrames,
                detector:      detector,
                deepgram:      deepgram,
                groq:          groq,
                elevenlabs:    elevenlabs,
                store:         store,
                sessionID:     sid,
                memorySummary: memSummary
            )
        }
    }

    func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        wakeWord.stop()
        capture.stop()
        AudioSessionManager.shared.deactivate()
        // ElevenLabsService is @MainActor — stopPlayback() is a direct call here.
        elevenlabsService?.stopPlayback()
        if let deepgram = deepgramService { Task { await deepgram.disconnect() } }
        if let groq     = groqService     { Task { await groq.clearHistory() } }

        // Summarise the session in the background before clearing the store reference.
        if let store = memoryStore, let groq = groqService {
            let sid = sessionID
            Task.detached {
                await MemorySummariser(groq: groq, store: store).summarise(sessionID: sid)
            }
        }

        deepgramService   = nil
        groqService       = nil
        elevenlabsService = nil
        memoryStore       = nil
        state = .idle
    }

    // MARK: – Pipeline loop (off main thread)

    private nonisolated func runLoop(
        audioFrames:   AsyncStream<[Int16]>,
        detector:      WakeWordDetector,
        deepgram:      DeepgramService,
        groq:          GroqService,
        elevenlabs:    ElevenLabsService,
        store:         MemoryStore?,
        sessionID:     String,
        memorySummary: String
    ) async {
        defer { Task { await deepgram.disconnect() } }

        var session: SpeechCaptureSession? = nil

        for await frame in audioFrames {
            guard !Task.isCancelled else { break }

            if let active = session {
                // ── CAPTURE MODE ──────────────────────────────────────────────
                switch active.process(frame: frame) {
                case .streaming(let chunk):
                    await deepgram.send(chunk)
                case .complete(_, let reason):
                    session = nil
                    await transcribeAndRespond(
                        deepgram:      deepgram,
                        groq:          groq,
                        elevenlabs:    elevenlabs,
                        store:         store,
                        sessionID:     sessionID,
                        memorySummary: memorySummary,
                        reason:        reason
                    )
                }
            } else {
                // ── WAKE-WORD MODE ────────────────────────────────────────────
                let detected = (try? detector.process(frame: frame)) ?? false
                if detected {
                    do {
                        try await deepgram.connect()
                    } catch {
                        print("[AudioPipeline] Deepgram connect failed: \(error.localizedDescription)")
                        continue
                    }
                    session = SpeechCaptureSession()
                    await setState(.capturing)
                }
            }
        }
    }

    // MARK: – STT → LLM → TTS sequence (nonisolated, called from runLoop)

    private nonisolated func transcribeAndRespond(
        deepgram:      DeepgramService,
        groq:          GroqService,
        elevenlabs:    ElevenLabsService,
        store:         MemoryStore?,
        sessionID:     String,
        memorySummary: String,
        reason:        SpeechCaptureSession.StopReason
    ) async {

        // ── Step 1: Deepgram — finalise transcript ────────────────────────────
        let transcript: String
        do {
            transcript = try await deepgram.finalise()
        } catch DeepgramService.DeepgramError.emptyTranscript {
            print("[AudioPipeline] No speech detected, returning to idle")
            await setState(.idle)
            return
        } catch {
            print("[AudioPipeline] STT error: \(error.localizedDescription)")
            await setState(.idle)
            return
        }

        print("[AudioPipeline] Transcript (\(reason)): \"\(transcript)\"")
        await setState(.processing)

        // ── Step 2: Groq — generate response ─────────────────────────────────
        let response: String
        do {
            response = try await groq.complete(transcript: transcript, memorySummary: memorySummary)
        } catch GroqService.GroqError.rateLimited {
            print("[AudioPipeline] Groq rate limited")
            await setState(.idle)
            return
        } catch {
            print("[AudioPipeline] LLM error: \(error.localizedDescription)")
            await setState(.idle)
            return
        }

        // ── Step 3: Persist the exchange ──────────────────────────────────────
        if let store {
            try? await store.saveTurn(sessionID: sessionID, role: "user",      content: transcript)
            try? await store.saveTurn(sessionID: sessionID, role: "assistant", content: response)
        }

        // ── Step 4: ElevenLabs — synthesise and play ──────────────────────────
        // setState(.speaking) before speak() so the UI updates immediately.
        // The pipeline loop stays suspended for the entire fetch + playback,
        // which is what prevents wake-word re-triggering during Doki's response.
        await setState(.speaking)
        do {
            try await elevenlabs.speak(response)
        } catch {
            // Silent fallback: log the failure but do not propagate.
            // The user hears nothing; the pipeline returns to idle and resumes
            // listening. This is preferable to crashing or freezing.
            print("[AudioPipeline] TTS failed (silent fallback): \(error.localizedDescription)")
        }

        await setState(.idle)
    }

    // MARK: – State helper (MainActor)

    private func setState(_ newState: PipelineState) {
        state = newState
    }
}
