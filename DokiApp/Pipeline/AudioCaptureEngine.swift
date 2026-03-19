import AVFoundation

/// Wraps AVAudioEngine for continuous low-latency PCM capture.
///
/// Taps at the hardware's native format, converts to 16 kHz mono Int16 via
/// AVAudioConverter, and accumulates samples into exactly 512-sample frames —
/// the format Porcupine requires. Tap callback and conversion run on
/// AVAudioEngine's internal thread; AsyncStream continuation is thread-safe.
final class AudioCaptureEngine {

    static let porcupineSampleRate: Double = 16_000
    static let porcupineFrameLength: Int   = 512

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var sampleAccumulator: [Int16] = []

    /// Frames of exactly 512 Int16 samples at 16 kHz mono.
    /// Replaced on each `start()` call; capture the reference after calling `start()`.
    private(set) var audioFrames: AsyncStream<[Int16]> = AsyncStream { $0.finish() }
    private var continuation: AsyncStream<[Int16]>.Continuation?

    // MARK: – Lifecycle

    /// Starts the audio engine and installs the tap.
    /// `AudioSessionManager.requestPermissionAndConfigure()` must have been
    /// called before this.
    func start() throws {
        // Fresh stream for each start so consumers always get live frames.
        let (stream, cont) = AsyncStream<[Int16]>.makeStream()
        audioFrames   = stream
        continuation  = cont
        sampleAccumulator = []

        let inputNode     = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.unavailableHardwareFormat
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.porcupineSampleRate,
            channels: 1,
            interleaved: true
        )!

        guard let avConverter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter = avConverter

        // Request a buffer size that produces roughly one Porcupine frame after
        // downsampling. The value is advisory — AVAudioEngine may deliver more or fewer.
        let advisorySize = AVAudioFrameCount(
            Double(Self.porcupineFrameLength) * hardwareFormat.sampleRate / Self.porcupineSampleRate
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: advisorySize,
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, using: avConverter, targetFormat: targetFormat)
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        sampleAccumulator = []
        continuation?.finish()
        continuation = nil
    }

    // MARK: – Conversion and framing

    private func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio          = Self.porcupineSampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return }

        // The converter pulls from this block exactly once per convert call.
        var inputProvided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !inputProvided else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputProvided = true
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil,
              let int16Data = outputBuffer.int16ChannelData else { return }

        let count = Int(outputBuffer.frameLength)
        sampleAccumulator += UnsafeBufferPointer(start: int16Data[0], count: count)

        // Drain accumulator in 512-sample chunks.
        while sampleAccumulator.count >= Self.porcupineFrameLength {
            let frame = Array(sampleAccumulator.prefix(Self.porcupineFrameLength))
            sampleAccumulator.removeFirst(Self.porcupineFrameLength)
            continuation?.yield(frame)
        }
    }
}

enum AudioCaptureError: Error {
    case unavailableHardwareFormat
    case converterCreationFailed
}
