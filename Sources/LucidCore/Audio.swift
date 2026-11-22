import Foundation

/// Encodes PCM samples as a WAV file in memory.
public enum WAV {
    /// 16-bit mono PCM with a standard 44-byte header.
    public static func encode(samples: [Int16], sampleRate: Int = 16_000) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + samples.count * 2)

        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        text("RIFF")
        uint32(36 + dataSize)
        text("WAVE")
        text("fmt ")
        uint32(16)                        // size of the format block
        uint16(1)                         // PCM
        uint16(1)                         // mono
        uint32(UInt32(sampleRate))
        uint32(UInt32(sampleRate * 2))    // bytes per second
        uint16(2)                         // bytes per sample frame
        uint16(16)                        // bits per sample
        text("data")
        uint32(dataSize)
        // WAV is little-endian, and so is every Mac, so the samples can be copied as they are.
        samples.withUnsafeBufferPointer { data.append($0) }
        return data
    }

    /// The duration of a PCM WAV file, read from its header. Nil when the data is not a WAV.
    public static func seconds(of data: Data) -> Double? {
        guard data.count >= 44 else { return nil }
        let bytes = [UInt8](data.prefix(44))
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> Int { uint16(offset) | uint16(offset + 2) << 16 }

        let bytesPerSecond = uint32(24) * uint16(22) * uint16(34) / 8
        guard bytesPerSecond > 0 else { return nil }
        return Double(data.count - 44) / Double(bytesPerSecond)
    }
}

/// Whisper's encoder always processes a fixed window of audio: 1500 frames, which is 30 seconds.
/// A smaller window is faster, but the turbo model produces garbage below half size.
public enum WhisperWindow {
    /// What the server takes to mean "the full window".
    public static let full = 0
    public static let half = 768
    private static let framesPerSecond = 50.0
    private static let margin = 64.0

    /// The `audio_ctx` value to send for a clip of this length.
    public static func audioContext(forSeconds seconds: Double) -> Int {
        seconds * framesPerSecond + margin <= Double(half) ? half : full
    }
}

/// Decides whether a recording contains anything worth transcribing.
///
/// Speech models invent text when given silence, so silent recordings are dropped first.
public enum AudioGate {
    public static let minimumDuration: TimeInterval = 0.3

    /// True when at least `minimumWindows` windows have an RMS level of `threshold` or more.
    /// Levels are on a scale where full volume is 1.0.
    public static func hasSpeech(
        samples: [Int16],
        sampleRate: Int = 16_000,
        window: TimeInterval = 0.05,
        threshold: Double = 0.008,
        minimumWindows: Int = 3
    ) -> Bool {
        guard sampleRate > 0, Double(samples.count) / Double(sampleRate) >= minimumDuration else {
            return false
        }
        let size = max(1, Int(Double(sampleRate) * window))
        var loudWindows = 0
        var start = 0
        while start + size <= samples.count {
            var sumOfSquares = 0.0
            for index in start..<(start + size) {
                let level = Double(samples[index]) / 32768.0
                sumOfSquares += level * level
            }
            if (sumOfSquares / Double(size)).squareRoot() >= threshold {
                loudWindows += 1
                if loudWindows >= minimumWindows { return true }
            }
            start += size
        }
        return false
    }
}
