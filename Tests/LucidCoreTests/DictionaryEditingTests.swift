import LucidCore

func dictionaryEditingTests() {
    suite("DictionaryEditing") {
        test("adds a trimmed term once") {
            var dictionary = PersonalDictionary()
            expectTrue(dictionary.addTerm("  GitHub "))
            expectFalse(dictionary.addTerm("github"))
            expectFalse(dictionary.addTerm("   "))
            expectEqual(dictionary.terms, ["GitHub"])
        }

        test("removes a term") {
            var dictionary = PersonalDictionary(terms: ["GitHub", "Lucid"])
            dictionary.removeTerm("GitHub")
            expectEqual(dictionary.terms, ["Lucid"])
        }

        test("adds a replacement and refuses blanks") {
            var dictionary = PersonalDictionary()
            expectTrue(dictionary.addReplacement(from: " jon ", to: " John "))
            expectFalse(dictionary.addReplacement(from: "", to: "John"))
            expectFalse(dictionary.addReplacement(from: "jon", to: "  "))
            expectEqual(dictionary.replacements, [Replacement(from: "jon", to: "John")])
        }

        test("a new replacement for the same phrase replaces the old one") {
            var dictionary = PersonalDictionary(replacements: [
                Replacement(from: "jon", to: "John"),
                Replacement(from: "cube control", to: "kubectl"),
            ])
            expectTrue(dictionary.addReplacement(from: "Jon", to: "Jonathan"))
            expectEqual(dictionary.replacements, [
                Replacement(from: "cube control", to: "kubectl"),
                Replacement(from: "Jon", to: "Jonathan"),
            ])
        }

        test("removes a replacement") {
            var dictionary = PersonalDictionary(replacements: [Replacement(from: "jon", to: "John")])
            dictionary.removeReplacement(from: "jon")
            expectEqual(dictionary.replacements, [])
        }
    }
}
