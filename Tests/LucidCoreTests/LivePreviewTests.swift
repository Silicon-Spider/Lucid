import Foundation
import LucidCore

func livePreviewTests() {
    suite("LivePreview") {
        test("shows a short hearing whole, on one line") {
            expectEqual(LivePreview.text(for: " So I was thinking we could meet."), "So I was thinking we could meet.")
            expectEqual(LivePreview.text(for: "first line\nsecond   line\n"), "first line second line")
        }

        test("shows only the last words of a long hearing") {
            let heard = "So I was thinking we could meet at three at the usual place and then walk over to the station"
            let text = LivePreview.text(for: heard, limit: 30)
            // "and then walk over to the station" would be 33 characters, so "and" is left out.
            expectEqual(text, "…then walk over to the station")
            expectTrue(heard.hasSuffix(String(text.dropFirst())), "it must be the end of what was heard")
        }

        test("fills the line as far as whole words allow") {
            // "meet at three at the usual place and walk there" is 47 characters. One more word would not fit in 48.
            let heard = "we could meet at three at the usual place and walk there"
            expectEqual(LivePreview.text(for: heard), "…meet at three at the usual place and walk there")
            expectEqual(LivePreview.text(for: "meet at three at the usual place and walk there"), "meet at three at the usual place and walk there")
        }

        test("keeps a last word that is longer than the line") {
            expectEqual(LivePreview.text(for: "see pneumonoultramicroscopicsilicovolcanoconiosis", limit: 10), "…pneumonoultramicroscopicsilicovolcanoconiosis")
        }

        test("shows nothing for silence, or for the engine's notes about the sound") {
            expectEqual(LivePreview.text(for: ""), "")
            expectEqual(LivePreview.text(for: "   \n "), "")
            expectEqual(LivePreview.text(for: "[BLANK_AUDIO]"), "")
            expectEqual(LivePreview.text(for: " (silence) [Music] "), "")
            expectEqual(LivePreview.text(for: "[BLANK_AUDIO] okay so"), "okay so")
        }

        test("sends only the end of a long recording") {
            let short = [Int16](repeating: 1, count: 16_000 * 5)
            expectEqual(LivePreview.window(of: short).count, short.count)
            var long = [Int16](repeating: 1, count: 16_000 * 30)
            long[long.count - 1] = 7
            let window = LivePreview.window(of: long)
            expectEqual(window.count, 16_000 * 12)
            expectEqual(window.last, 7)
            // The window must fit the speech engine's fast half window.
            expectEqual(WhisperWindow.audioContext(forSeconds: LivePreview.windowSeconds), WhisperWindow.half)
        }

        test("waits for a second of speech, then for a second of new speech") {
            expectFalse(LivePreview.shouldRequest(recordedSeconds: 0.6, atLastRequest: nil, lastTook: 0))
            expectTrue(LivePreview.shouldRequest(recordedSeconds: 1.0, atLastRequest: nil, lastTook: 0))
            expectFalse(LivePreview.shouldRequest(recordedSeconds: 1.8, atLastRequest: 1.0, lastTook: 0.4))
            expectTrue(LivePreview.shouldRequest(recordedSeconds: 2.0, atLastRequest: 1.0, lastTook: 0.4))
        }

        test("spaces previews further apart when the engine is slow") {
            // A preview that took 1.5 s is followed by 3 s of new audio before the next.
            expectFalse(LivePreview.shouldRequest(recordedSeconds: 3.5, atLastRequest: 1.0, lastTook: 1.5))
            expectTrue(LivePreview.shouldRequest(recordedSeconds: 4.0, atLastRequest: 1.0, lastTook: 1.5))
        }
    }
}
