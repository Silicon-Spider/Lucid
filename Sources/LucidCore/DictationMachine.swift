import Foundation

/// The dictation state machine: key events in, recording actions out.
///
/// It holds no timers and reads no clock. The caller passes the time of each event, and
/// sends `tick` regularly while the machine is not idle.
public struct DictationMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// The hotkey is down and has not been released.
        case holding(startedAt: TimeInterval)
        /// The hotkey was tapped. A second press inside the window means hands-free.
        case tapPending(startedAt: TimeInterval, releasedAt: TimeInterval)
        /// Recording continues with no key held, until the hotkey is pressed again.
        case handsFree(startedAt: TimeInterval)
        case processing
    }

    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        /// Any key other than the hotkey and Escape.
        case otherKeyDown
        case escape
        case tick
        /// The dictation that was being processed has been inserted or abandoned.
        case finished
    }

    public enum Action: Equatable, Sendable {
        case startRecording
        case stopAndProcess
        /// Stop recording and throw the audio away.
        case discard
        case enterHandsFree
        /// The hotkey was pressed while the last dictation is still being processed.
        case busy
    }

    public struct Timing: Equatable, Sendable {
        /// A press shorter than this is a tap, not a dictation.
        public var holdThreshold: TimeInterval = 0.3
        /// How long after a tap a second press still counts as a double tap.
        public var doubleTapWindow: TimeInterval = 0.4
        /// A recording stops by itself after this long.
        public var maxDuration: TimeInterval = 600

        public init() {}
    }

    public private(set) var state: State = .idle
    public var timing: Timing

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// True while audio is being recorded. This is when Escape belongs to Lucid.
    public var isRecording: Bool {
        switch state {
        case .holding, .tapPending, .handsFree: return true
        case .idle, .processing: return false
        }
    }

    /// Applies one event and returns what the caller should now do.
    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Action] {
        switch (state, event) {
        case (.idle, .hotkeyDown):
            state = .holding(startedAt: time)
            return [.startRecording]

        case (.holding(let startedAt), .hotkeyUp):
            if time - startedAt >= timing.holdThreshold {
                state = .processing
                return [.stopAndProcess]
            }
            // Recording carries on, so nothing is lost if this turns out to be a double tap.
            state = .tapPending(startedAt: startedAt, releasedAt: time)
            return []

        case (.holding, .otherKeyDown), (.holding, .escape),
             (.tapPending, .otherKeyDown), (.tapPending, .escape),
             (.handsFree, .escape):
            state = .idle
            return [.discard]

        case (.tapPending(let startedAt, _), .hotkeyDown):
            state = .handsFree(startedAt: startedAt)
            return [.enterHandsFree]

        case (.tapPending(_, let releasedAt), .tick):
            if time - releasedAt >= timing.doubleTapWindow {
                state = .idle
                return [.discard]
            }
            return []

        case (.handsFree, .hotkeyDown):
            state = .processing
            return [.stopAndProcess]

        case (.holding(let startedAt), .tick), (.handsFree(let startedAt), .tick):
            if time - startedAt >= timing.maxDuration {
                state = .processing
                return [.stopAndProcess]
            }
            return []

        case (.processing, .hotkeyDown):
            return [.busy]

        case (.processing, .finished):
            state = .idle
            return []

        default:
            return []
        }
    }
}
