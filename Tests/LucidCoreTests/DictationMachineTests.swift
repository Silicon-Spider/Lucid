import LucidCore

func dictationMachineTests() {
    suite("DictationMachine") {
        test("hold and release dictates") {
            var machine = DictationMachine()
            expectEqual(machine.handle(.hotkeyDown, at: 10.0), [.startRecording])
            expectEqual(machine.state, .holding(startedAt: 10.0))
            expectTrue(machine.isRecording)
            expectEqual(machine.handle(.hotkeyUp, at: 12.0), [.stopAndProcess])
            expectEqual(machine.state, .processing)
            expectFalse(machine.isRecording)
            expectEqual(machine.handle(.finished, at: 13.0), [])
            expectEqual(machine.state, .idle)
        }

        test("a quick tap is discarded if no second press follows") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            expectEqual(machine.handle(.hotkeyUp, at: 10.1), [])
            expectEqual(machine.state, .tapPending(startedAt: 10.0, releasedAt: 10.1))
            expectTrue(machine.isRecording)
            expectEqual(machine.handle(.tick, at: 10.3), [])
            expectEqual(machine.handle(.tick, at: 10.5), [.discard])
            expectEqual(machine.state, .idle)
        }

        test("a double tap enters hands-free, and the next press ends it") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            _ = machine.handle(.hotkeyUp, at: 10.1)
            expectEqual(machine.handle(.hotkeyDown, at: 10.3), [.enterHandsFree])
            expectEqual(machine.state, .handsFree(startedAt: 10.0))
            expectEqual(machine.handle(.hotkeyUp, at: 10.4), [])
            expectEqual(machine.handle(.otherKeyDown, at: 12.0), [])
            expectEqual(machine.state, .handsFree(startedAt: 10.0))
            expectEqual(machine.handle(.hotkeyDown, at: 30.0), [.stopAndProcess])
            expectEqual(machine.state, .processing)
        }

        test("another key while holding means the hotkey was a modifier") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            expectEqual(machine.handle(.otherKeyDown, at: 10.5), [.discard])
            expectEqual(machine.state, .idle)
            expectEqual(machine.handle(.hotkeyUp, at: 11.0), [])
            expectEqual(machine.state, .idle)
        }

        test("escape discards in every recording state") {
            var holding = DictationMachine()
            _ = holding.handle(.hotkeyDown, at: 1.0)
            expectEqual(holding.handle(.escape, at: 2.0), [.discard])
            expectEqual(holding.state, .idle)

            var pending = DictationMachine()
            _ = pending.handle(.hotkeyDown, at: 1.0)
            _ = pending.handle(.hotkeyUp, at: 1.1)
            expectEqual(pending.handle(.escape, at: 1.2), [.discard])

            var handsFree = DictationMachine()
            _ = handsFree.handle(.hotkeyDown, at: 1.0)
            _ = handsFree.handle(.hotkeyUp, at: 1.1)
            _ = handsFree.handle(.hotkeyDown, at: 1.2)
            expectEqual(handsFree.handle(.escape, at: 5.0), [.discard])
            expectEqual(handsFree.state, .idle)
        }

        test("escape and other keys do nothing when idle") {
            var machine = DictationMachine()
            expectEqual(machine.handle(.escape, at: 1.0), [])
            expectEqual(machine.handle(.otherKeyDown, at: 1.0), [])
            expectEqual(machine.handle(.hotkeyUp, at: 1.0), [])
            expectEqual(machine.handle(.tick, at: 1.0), [])
            expectFalse(machine.isRecording)
        }

        test("a recording stops itself at the maximum length") {
            var holding = DictationMachine()
            _ = holding.handle(.hotkeyDown, at: 0)
            expectEqual(holding.handle(.tick, at: 599), [])
            expectEqual(holding.handle(.tick, at: 600), [.stopAndProcess])
            expectEqual(holding.state, .processing)

            var handsFree = DictationMachine()
            _ = handsFree.handle(.hotkeyDown, at: 0)
            _ = handsFree.handle(.hotkeyUp, at: 0.1)
            _ = handsFree.handle(.hotkeyDown, at: 0.2)
            expectEqual(handsFree.handle(.tick, at: 600), [.stopAndProcess])
        }

        test("the hotkey is ignored while processing") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 0)
            _ = machine.handle(.hotkeyUp, at: 1)
            expectEqual(machine.handle(.hotkeyDown, at: 1.5), [.busy])
            expectEqual(machine.handle(.hotkeyUp, at: 1.6), [])
            expectEqual(machine.state, .processing)
            _ = machine.handle(.finished, at: 2)
            expectEqual(machine.handle(.hotkeyDown, at: 3), [.startRecording])
        }

        test("timing can be changed") {
            var timing = DictationMachine.Timing()
            timing.holdThreshold = 1.0
            var machine = DictationMachine(timing: timing)
            _ = machine.handle(.hotkeyDown, at: 0)
            expectEqual(machine.handle(.hotkeyUp, at: 0.5), [])
            expectEqual(machine.state, .tapPending(startedAt: 0, releasedAt: 0.5))
        }
    }
}
