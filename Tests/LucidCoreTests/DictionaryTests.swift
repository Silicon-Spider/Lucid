import Foundation
import LucidCore

func dictionaryTests() {
    suite("PersonalDictionary") {
        test("replaces whole words in any capitalisation") {
            let dictionary = PersonalDictionary(replacements: [Replacement(from: "jon", to: "John")])
            expectEqual(dictionary.apply(to: "Ask jon and Jon's team."), "Ask John and John's team.")
            expectEqual(dictionary.apply(to: "Ask Jonathan."), "Ask Jonathan.")
        }

        test("the longest phrase wins") {
            let dictionary = PersonalDictionary(replacements: [
                Replacement(from: "cube", to: "Kube"),
                Replacement(from: "cube control", to: "kubectl"),
            ])
            expectEqual(dictionary.apply(to: "Run cube control now."), "Run kubectl now.")
            expectEqual(dictionary.apply(to: "A cube."), "A Kube.")
        }

        test("terms enforce their saved capitalisation") {
            let dictionary = PersonalDictionary(terms: ["GitHub", "macOS"])
            expectEqual(dictionary.apply(to: "Push to github from MacOS."), "Push to GitHub from macOS.")
        }

        test("a replacement's output is not replaced again") {
            let dictionary = PersonalDictionary(replacements: [
                Replacement(from: "alpha", to: "beta"),
                Replacement(from: "beta", to: "gamma"),
            ])
            expectEqual(dictionary.apply(to: "alpha beta"), "beta gamma")
        }

        test("a replacement beats a term for the same phrase") {
            let dictionary = PersonalDictionary(
                terms: ["lucid"],
                replacements: [Replacement(from: "lucid", to: "Lucid")]
            )
            expectEqual(dictionary.apply(to: "open lucid"), "open Lucid")
        }

        test("handles phrases with regex characters") {
            let dictionary = PersonalDictionary(replacements: [Replacement(from: "c plus plus", to: "C++")])
            expectEqual(dictionary.apply(to: "I write c plus plus."), "I write C++.")
        }

        test("ignores blank entries and an empty dictionary") {
            expectEqual(PersonalDictionary.empty.apply(to: "unchanged"), "unchanged")
            let dictionary = PersonalDictionary(terms: ["  "], replacements: [Replacement(from: "", to: "x")])
            expectEqual(dictionary.apply(to: "unchanged"), "unchanged")
        }

        test("builds a glossary for the speech model") {
            let dictionary = PersonalDictionary(
                terms: ["Lucid", "Kubernetes", "lucid"],
                replacements: [Replacement(from: "jon", to: "John")]
            )
            expectEqual(dictionary.recognitionPrompt(), "Glossary: Lucid, Kubernetes, John.")
            expectEqual(PersonalDictionary.empty.recognitionPrompt(), "")
            expectEqual(dictionary.recognitionPrompt(maxCharacters: 20), "Glossary: Lucid.")
        }

        test("saves and loads") {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("lucid-tests-\(UUID().uuidString)")
            let url = folder.appendingPathComponent("dictionary.json")
            defer { try? FileManager.default.removeItem(at: folder) }

            expectEqual(try PersonalDictionary.load(from: url), PersonalDictionary.empty)

            let dictionary = PersonalDictionary(
                terms: ["GitHub"],
                replacements: [Replacement(from: "jon", to: "John")]
            )
            try dictionary.save(to: url)
            expectEqual(try PersonalDictionary.load(from: url), dictionary)
        }
    }
}
