import LucidCore

func insertionTests() {
    suite("Insertion") {
        test("detects the middle of a sentence") {
            expectTrue(InsertionPlanner.isMidSentence(before: "Hello world"))
            expectTrue(InsertionPlanner.isMidSentence(before: "Hello world "))
            expectTrue(InsertionPlanner.isMidSentence(before: "first,"))
            expectTrue(InsertionPlanner.isMidSentence(before: "("))
        }

        test("detects the start of a sentence") {
            expectFalse(InsertionPlanner.isMidSentence(before: nil))
            expectFalse(InsertionPlanner.isMidSentence(before: ""))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done. "))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done."))
            expectFalse(InsertionPlanner.isMidSentence(before: "Really? "))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done.\n"))
            expectFalse(InsertionPlanner.isMidSentence(before: "word\n"))
            expectFalse(InsertionPlanner.isMidSentence(before: "   "))
        }

        test("adds a space after a word or punctuation") {
            expectEqual(InsertionPlanner.textToInsert("and more", before: "Hello world"), " and more")
            expectEqual(InsertionPlanner.textToInsert("Next one.", before: "Done."), " Next one.")
        }

        test("adds no space where one is not wanted") {
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: nil), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: ""), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("and more", before: "Hello world "), "and more")
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: "Done.\n"), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("quoted", before: "("), "quoted")
            expectEqual(InsertionPlanner.textToInsert("quoted", before: "“"), "quoted")
            expectEqual(InsertionPlanner.textToInsert("\nNew line.", before: "Done."), "\nNew line.")
            expectEqual(InsertionPlanner.textToInsert(", and so on", before: "word"), ", and so on")
            expectEqual(InsertionPlanner.textToInsert("", before: "word"), "")
        }

        test("hotkey choices have key codes and titles") {
            expectEqual(HotkeyChoice.fn.keyCode, 63)
            expectEqual(HotkeyChoice.rightOption.keyCode, 61)
            expectEqual(HotkeyChoice.rightCommand.keyCode, 54)
            expectEqual(HotkeyChoice.allCases.map(\.title), ["Fn (Globe)", "Right Option", "Right Command"])
        }

        test("the default hotkey depends on the kind of Mac") {
            expectEqual(HotkeyChoice.standard(forModelName: "MacBook Air"), .fn)
            expectEqual(HotkeyChoice.standard(forModelName: "MacBook Pro"), .fn)
            expectEqual(HotkeyChoice.standard(forModelName: "Mac mini"), .rightOption)
            expectEqual(HotkeyChoice.standard(forModelName: ""), .rightOption)
        }
    }
}
