import Foundation

/// The words shown while the user is still speaking: what the speech engine has heard so far.
///
/// A preview is a rough first hearing. It is only shown, never inserted. The text that is
/// inserted comes from transcribing the whole recording once the user stops.
public enum LivePreview {
    /// How much of the end of the recording is transcribed for a preview. It fits the speech
    /// engine's fast half window (see `WhisperWindow`), so a preview costs the same however
    /// long the dictation is.
    public static let windowSeconds = 12.0
    /// No preview is asked for until this much has been recorded.
    public static let firstAfterSeconds = 1.0
    /// The least new audio between one preview and the next.
    public static let minimumNewSeconds = 1.0

    /// The end of a recording to send for a preview.
    public static func window(of samples: [Int16], sampleRate: Int = 16_000) -> [Int16] {
        let limit = Int(windowSeconds * Double(sampleRate))
        return samples.count > limit ? Array(samples.suffix(limit)) : samples
    }

    /// Whether to ask for another preview. `atLastRequest` is how much had been recorded when
    /// the last one was asked for, and `lastTook` how long it took to come back.
    ///
    /// The engine does one thing at a time, so the final transcription waits for a preview that
    /// is under way. Spacing previews at least twice their own duration apart keeps the engine
    /// free more often than not when the user stops, on a slow Mac as on a fast one.
    public static func shouldRequest(recordedSeconds: Double, atLastRequest: Double?, lastTook: Double) -> Bool {
        guard recordedSeconds >= firstAfterSeconds else { return false }
        guard let atLastRequest else { return true }
        return recordedSeconds - atLastRequest >= max(minimumNewSeconds, 2 * lastTook)
    }

    /// What to show for what the engine heard: its last few words on one line, at most `limit`
    /// characters, with an ellipsis in front when earlier words were left out.
    public static func text(for heard: String, limit: Int = 48) -> String {
        // A tag such as [BLANK_AUDIO] is the engine describing the sound, not something the user said.
        let words = RulesCleaner.removeTags(heard).split(whereSeparator: { $0.isWhitespace })
        var shown: [Substring] = []
        var length = 0
        for word in words.reversed() {
            let added = word.count + (shown.isEmpty ? 0 : 1)
            // Always keep the last word, however long it is.
            if !shown.isEmpty, length + added > limit { break }
            shown.append(word)
            length += added
        }
        guard !shown.isEmpty else { return "" }
        let text = shown.reversed().joined(separator: " ")
        return shown.count < words.count ? "…" + text : text
    }
}
