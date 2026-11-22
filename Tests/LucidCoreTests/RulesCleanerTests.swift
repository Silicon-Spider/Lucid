import LucidCore

func rulesCleanerTests() {
    suite("RulesCleaner") {
        func light(_ text: String) -> String { RulesCleaner.clean(text, level: .light) }

        test("removes a filler at the start and recapitalises") {
            expectEqual(light("Um, so I think we should go."), "So I think we should go.")
        }

        test("removes a filler mid-sentence with its commas") {
            expectEqual(light("I think, um, we should go."), "I think we should go.")
        }

        test("removes a bare filler mid-sentence") {
            expectEqual(light("I went to the uh store."), "I went to the store.")
        }

        test("keeps the full stop when a filler ends a sentence") {
            expectEqual(light("Well, um. I don't know."), "Well. I don't know.")
        }

        test("removes a filler that is a sentence by itself") {
            expectEqual(light("Okay. Um. Let's start."), "Okay. Let's start.")
            expectEqual(light("Hmm... let me think."), "Let me think.")
            expectEqual(light("Um."), "")
        }

        test("removes a run of fillers") {
            expectEqual(light("Um, uh, so yeah."), "So yeah.")
        }

        test("removes elongated fillers") {
            expectEqual(light("Ummm I guess uhh maybe."), "I guess maybe.")
        }

        test("removes a filler at the end of the text") {
            expectEqual(light("I think so, um"), "I think so")
        }

        test("leaves real words alone") {
            expectEqual(light("The umbrella is in her room, uh-huh."), "The umbrella is in her room, uh-huh.")
            expectEqual(light("To err is human."), "To err is human.")
            expectEqual(light("Mm-hmm, that works."), "Mm-hmm, that works.")
            expectEqual(light("She works in the ER."), "She works in the ER.")
        }

        test("does not capitalise a word with an internal capital") {
            expectEqual(light("Um, iPhone sales are up."), "iPhone sales are up.")
        }

        test("collapses repeated function words") {
            expectEqual(light("I I think the the plan is good."), "I think the plan is good.")
            expectEqual(light("We, we should go to to the park."), "We should go to the park.")
            expectEqual(light("I I'm not sure."), "I'm not sure.")
            expectEqual(light("I, um, I think so."), "I think so.")
        }

        test("keeps genuine doubles") {
            expectEqual(light("He had had enough."), "He had had enough.")
            expectEqual(light("I know that that is true."), "I know that that is true.")
            expectEqual(light("Add it to to-do list."), "Add it to to-do list.")
        }

        test("removes non-speech tags") {
            expectEqual(light("[BLANK_AUDIO]"), "")
            expectEqual(light("Hello [MUSIC] there (silence)."), "Hello there.")
        }

        test("turns spoken line commands into breaks") {
            expectEqual(light("First point. New line. Second point."), "First point.\nSecond point.")
            expectEqual(light("Dear Sam, new paragraph, thanks for the note."), "Dear Sam,\n\nThanks for the note.")
            expectEqual(light("Start a new paragraph. Next topic."), "\n\nNext topic.")
            expectEqual(light("One. New line. New line. Two."), "One.\n\nTwo.")
        }

        test("leaves 'new line' alone inside a sentence") {
            expectEqual(light("We opened a new line of stores."), "We opened a new line of stores.")
        }

        test("handles a filler next to a line command") {
            expectEqual(light("Okay, um, new line, next item."), "Okay\nNext item.")
            expectEqual(light("Done. New line. Um, the next one."), "Done.\nThe next one.")
        }

        test("off level only strips tags and applies line commands") {
            expectEqual(
                RulesCleaner.clean("Um, I I think so. New line. [MUSIC] Yes.", level: .off),
                "Um, I I think so.\nYes."
            )
        }

        test("tidies spacing without touching dotted names") {
            expectEqual(light("We use .NET and , um , Swift ."), "We use .NET and Swift.")
        }

        test("returns empty text unchanged") {
            expectEqual(light(""), "")
            expectEqual(light("   "), "")
        }
    }
}
