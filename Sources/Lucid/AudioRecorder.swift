import AVFoundation

enum RecorderError: Error {
    case noInput
}

/// Records the default microphone as 16 kHz mono samples, the format the speech engine expects.
final class AudioRecorder {
    /// Called on the main thread with the level of each chunk of audio.
    /// Speech is roughly 0.02 to 0.2.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start() throws {
        stop()
        // A fresh engine each time, so a change of microphone between dictations is picked up.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.noInput
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// How much has been recorded so far, in seconds.
    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / outputFormat.sampleRate
    }

    /// The most recent audio, at most `seconds` of it, while recording carries on.
    func latest(seconds: Double) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples.suffix(max(0, Int(seconds * outputFormat.sampleRate))))
    }

    /// Stops recording and returns everything captured.
    @discardableResult
    func stop() -> [Int16] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        lock.lock()
        defer { lock.unlock() }
        let recorded = samples
        samples = []
        return recorded
    }

    /// Runs on the audio thread. Converts one buffer to 16 kHz mono and stores it.
    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = converted.int16ChannelData else { return }

        let count = Int(converted.frameLength)
        guard count > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel[0], count: count)
        var sumOfSquares: Float = 0
        for sample in chunk {
            let value = Float(sample) / 32768
            sumOfSquares += value * value
        }
        let level = (sumOfSquares / Float(count)).squareRoot()

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
        }
    }
}
