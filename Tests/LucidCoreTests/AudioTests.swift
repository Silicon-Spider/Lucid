import Foundation
import LucidCore

private func sine(seconds: Double, amplitude: Double, rate: Int = 16_000) -> [Int16] {
    (0..<Int(seconds * Double(rate))).map { index in
        Int16(amplitude * 32767 * sin(2 * Double.pi * 440 * Double(index) / Double(rate)))
    }
}

private func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: offset..<(offset + 4)).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

private func uint16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
}

func audioTests() {
    suite("Audio") {
        test("encodes a WAV header") {
            let data = WAV.encode(samples: [0, 1, -1, 32767, -32768], sampleRate: 16_000)
            expectEqual(data.count, 54)
            expectEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            expectEqual(uint32(data, at: 4), 46)
            expectEqual(String(decoding: data.subdata(in: 8..<16), as: UTF8.self), "WAVEfmt ")
            expectEqual(uint32(data, at: 16), 16)
            expectEqual(uint16(data, at: 20), 1)
            expectEqual(uint16(data, at: 22), 1)
            expectEqual(uint32(data, at: 24), 16_000)
            expectEqual(uint32(data, at: 28), 32_000)
            expectEqual(uint16(data, at: 32), 2)
            expectEqual(uint16(data, at: 34), 16)
            expectEqual(String(decoding: data.subdata(in: 36..<40), as: UTF8.self), "data")
            expectEqual(uint32(data, at: 40), 10)
        }

        test("encodes samples as little-endian 16-bit") {
            let data = WAV.encode(samples: [1, -1, -32768])
            expectEqual(Array(data.suffix(6)), [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80])
        }

        test("encodes an empty recording") {
            let data = WAV.encode(samples: [])
            expectEqual(data.count, 44)
            expectEqual(uint32(data, at: 40), 0)
        }

        test("detects speech-level audio") {
            expectTrue(AudioGate.hasSpeech(samples: sine(seconds: 1.0, amplitude: 0.2)))
        }

        test("rejects silence and quiet noise") {
            expectFalse(AudioGate.hasSpeech(samples: [Int16](repeating: 0, count: 16_000)))
            expectFalse(AudioGate.hasSpeech(samples: sine(seconds: 1.0, amplitude: 0.002)))
        }

        test("rejects a recording that is too short") {
            expectFalse(AudioGate.hasSpeech(samples: sine(seconds: 0.2, amplitude: 0.5)))
            expectFalse(AudioGate.hasSpeech(samples: []))
        }

        test("rejects a single click in silence") {
            var samples = [Int16](repeating: 0, count: 16_000)
            for index in 8_000..<8_160 { samples[index] = 30_000 }
            expectFalse(AudioGate.hasSpeech(samples: samples))
        }
    }
}
