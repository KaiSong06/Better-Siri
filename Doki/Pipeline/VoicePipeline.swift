import Foundation

/// Orchestrates the full Doki voice pipeline across all seven stages:
///
/// ```
/// 1. WakeWordDetector  — Porcupine listens for "Doki" on a continuous PCM stream
/// 2. AudioCaptureEngine— AVAudioEngine tap → 16 kHz Int16 mono frames
/// 3. DeepgramService   — WebSocket STT; silence/timeout ends capture
/// 4. MemoryStore       — loads session summaries (long-term memory)
///    CalendarService   — fetches upcoming events (injected per-turn)
/// 5. GroqService       — builds prompt (system + memory + calendar + history
///                        + transcript) and calls Llama 3 via Groq API
/// 6. ElevenLabsService — synthesises and plays TTS audio; loop suspends here,
///                        blocking wake-word re-detection during playback
/// 7. MemoryStore       — saves the user/assistant turn; MemorySummariser
///                        extracts facts at session end (background task)
/// ```
///
/// ## Threading
/// `@MainActor` owns all `@Published` state and lifecycle calls.
/// The pipeline loop runs in a `Task.detached` (off main thread) so audio
/// frame processing and network I/O never block the UI.
@MainActor
final class VoicePipeline: ObservableObject {

    @Published private(set) var state: PipelineState = .idle
    @Published private(set) var permissionDenied = false

    private let wakeWord = WakeWordDetector()
    private let capture  = AudioCaptureEngine()

    private var pipelineTask:      Task<Void, Never>?
    private var deepgramService:   DeepgramService?
    private var groqService:       GroqService?
    private var elevenlabsService: ElevenLabsService?
    private var memoryStore:       MemoryStore?
    private var calendarService:   CalendarService?
    private var sessionID:         String = ""
    private var memorySummary:     String = ""

    // MARK: – Lifecycle

    func start(
        picovoiceKey:  String,
        deepgramKey:   String,
        groqKey:       String,
        elevenlabsKey: String,
        voiceID:       String = "21m00Tcm4TlvDq8ikWAM"
    ) async {
        // ── Audio session ──────────────────────────────────────────────────────
        do {
            try await AudioSessionManager.shared.requestPermissionAndConfigure()
        } catch AudioSessionManager.PermissionError.denied {
            permissionDenied = true
            return
        } catch {
            print("[VoicePipeline] AVAudioSession error: \(error)")
            return
        }

        // ── Audio capture + wake word ──────────────────────────────────────────
        do {
            try capture.start()
            try wakeWord.start(accessKey: picovoiceKey)
        } catch {
            print("[VoicePipeline] Failed to start pipeline stages: \(error)")
            return
        }

        // ── Services ───────────────────────────────────────────────────────────
        let deepgram   = DeepgramService(apiKey: deepgramKey)
        let groq       = GroqService(apiKey: groqKey)
        let elevenlabs = ElevenLabsService(apiKey: elevenlabsKey, voiceID: voiceID)
        deepgramService   = deepgram
        groqService       = groq
        elevenlabsService = elevenlabs

        // ── Memory (stage 4a) ──────────────────────────────────────────────────
        // Load long-term summaries to inject into every Groq request this session.
        // Non-fatal: app runs fine without persistence.
        sessionID     = UUID().uuidString
        memorySummary = ""
        do {
            let store     = try MemoryStore()
            memorySummary = (try? await store.buildMemorySummary()) ?? ""
            memoryStore   = store
        } catch {
            print("[VoicePipeline] MemoryStore init failed (non-fatal): \(error)")
        }

        // ── Calendar (stage 4b) ────────────────────────────────────────────────
        // Request EventKit access; context is fetched fresh per turn.
        // Non-fatal: pipeline works without calendar permission.
        let calendar = CalendarService()
        await calendar.requestPermission()
        calendarService = calendar

        // ── Detach the pipeline loop off main thread ───────────────────────────
        let audioFrames = capture.audioFrames
        let detector    = wakeWord
        let store       = memoryStore
        let sid         = sessionID
        let memSummary  = memorySummary

        pipelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop(
                audioFrames:   audioFrames,
                detector:      detector,
                deepgram:      deepgram,
                groq:          groq,
                elevenlabs:    elevenlabs,
                store:         store,
                calendar:      calendar,
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
        elevenlabsService?.stopPlayback()
        if let deepgram = deepgramService { Task { await deepgram.disconnect() } }
        if let groq     = groqService     { Task { await groq.clearHistory()  } }

        // Stage 7b: summarise completed session in the background.
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
        calendarService   = nil
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
        calendar:      CalendarService,
        sessionID:     String,
        memorySummary: String
    ) async {
        defer { Task { await deepgram.disconnect() } }

        var session: SpeechCaptureSession? = nil

        for await frame in audioFrames {
            guard !Task.isCancelled else { break }

            if let active = session {
                // ── Stage 2: capturing ────────────────────────────────────────
                switch active.process(frame: frame) {
                case .streaming(let chunk):
                    await deepgram.send(chunk)
                case .complete(_, let reason):
                    session = nil
                    await process(
                        deepgram:      deepgram,
                        groq:          groq,
                        elevenlabs:    elevenlabs,
                        store:         store,
                        calendar:      calendar,
                        sessionID:     sessionID,
                        memorySummary: memorySummary,
                        reason:        reason
                    )
                }
            } else {
                // ── Stage 1: wake-word detection ──────────────────────────────
                let detected = (try? detector.process(frame: frame)) ?? false
                if detected {
                    do {
                        try await deepgram.connect()
                    } catch {
                        print("[VoicePipeline] Deepgram connect failed: \(error.localizedDescription)")
                        continue
                    }
                    session = SpeechCaptureSession()
                    await setState(.capturing)
                }
            }
        }
    }

    // MARK: – Stages 3–7 (STT → memory → LLM → TTS → persist)

    private nonisolated func process(
        deepgram:      DeepgramService,
        groq:          GroqService,
        elevenlabs:    ElevenLabsService,
        store:         MemoryStore?,
        calendar:      CalendarService,
        sessionID:     String,
        memorySummary: String,
        reason:        SpeechCaptureSession.StopReason
    ) async {

        // ── Stage 3: Deepgram STT ──────────────────────────────────────────────
        let transcript: String
        do {
            transcript = try await deepgram.finalise()
        } catch DeepgramService.DeepgramError.emptyTranscript {
            print("[VoicePipeline] No speech detected, returning to idle")
            await setState(.idle)
            return
        } catch {
            print("[VoicePipeline] STT error: \(error.localizedDescription)")
            await setState(.idle)
            return
        }

        print("[VoicePipeline] Transcript (\(reason)): \"\(transcript)\"")
        await setState(.processing)

        // ── Stage 4: memory + calendar context ────────────────────────────────
        // memorySummary was loaded once at session start (long-term memory).
        // Calendar context is fetched fresh every turn so newly added events
        // appear in the very next response.
        let calendarContext = await calendar.getUpcomingEvents()

        // ── Stage 5: Groq LLM ─────────────────────────────────────────────────
        // GroqService maintains the rolling in-session turn history internally.
        let response: String
        do {
            response = try await groq.complete(
                transcript:      transcript,
                memorySummary:   memorySummary,
                calendarContext: calendarContext
            )
        } catch GroqService.GroqError.rateLimited {
            print("[VoicePipeline] Groq rate limited")
            await setState(.idle)
            return
        } catch {
            print("[VoicePipeline] LLM error: \(error.localizedDescription)")
            await setState(.idle)
            return
        }

        // ── Stage 7a: persist turn ────────────────────────────────────────────
        if let store {
            try? await store.saveTurn(sessionID: sessionID, role: "user",      content: transcript)
            try? await store.saveTurn(sessionID: sessionID, role: "assistant", content: response)
        }

        // ── Stage 6: ElevenLabs TTS ───────────────────────────────────────────
        // setState(.speaking) before speak() so the UI updates immediately.
        // The pipeline loop stays suspended for the entire fetch + playback —
        // wake-word detection is naturally blocked while Doki is speaking.
        await setState(.speaking)
        do {
            try await elevenlabs.speak(response)
        } catch {
            print("[VoicePipeline] TTS failed (silent fallback): \(error.localizedDescription)")
        }

        await setState(.idle)
    }

    // MARK: – State helper (MainActor)

    private func setState(_ newState: PipelineState) {
        state = newState
    }
}
