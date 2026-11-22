import Foundation
import LucidCore

func whisperWindowTests() {
    suite("WhisperWindow") {
        test("reads the duration of an encoded WAV") {
            let data = WAV.encode(samples: [Int16](repeating: 0, count: 24_000))
            expectEqual(WAV.seconds(of: data), 1.5)
        }

        test("rejects data that is not a WAV") {
            expectEqual(WAV.seconds(of: Data("hello".utf8)), nil)
            expectEqual(WAV.seconds(of: Data()), nil)
            expectEqual(WAV.seconds(of: Data(repeating: 0, count: 100)), nil)
        }

        test("short clips use the half window") {
            expectEqual(WhisperWindow.audioContext(forSeconds: 0.5), 768)
            expectEqual(WhisperWindow.audioContext(forSeconds: 14.0), 768)
        }

        test("longer clips use the full window") {
            expectEqual(WhisperWindow.audioContext(forSeconds: 14.5), 0)
            expectEqual(WhisperWindow.audioContext(forSeconds: 120), 0)
        }
    }
}
