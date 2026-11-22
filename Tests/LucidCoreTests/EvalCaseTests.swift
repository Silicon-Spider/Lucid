import Foundation
import LucidCore

func evalCaseTests() {
    suite("EvalCase") {
        test("passes when every check is met") {
            let testCase = EvalCase(
                id: "a", group: "g", input: "x",
                mustContain: ["meet at"],
                mustContainAny: [["three", "3"]],
                mustNotContain: ["um", "two"]
            )
            expectEqual(testCase.failures(in: "Let's meet at 3."), [])
        }

        test("matches whole words in any capitalisation") {
            let testCase = EvalCase(id: "a", group: "g", input: "x", mustContain: ["friday"], mustNotContain: ["um"])
            expectEqual(testCase.failures(in: "The umbrella is due Friday."), [])
            expectEqual(
                testCase.failures(in: "Um, due Fridays."),
                ["missing \"friday\"", "should not contain \"um\""]
            )
        }

        test("checks exact output, capitals, patterns and length") {
            let testCase = EvalCase(
                id: "a", group: "g", input: "x",
                exact: "Do you want lunch?",
                mustContainCased: ["Do you"],
                mustMatch: ["\\?\\s*$"],
                mustNotMatch: ["(?m)^\\s*[-•*]\\s"],
                maxWords: 4
            )
            expectEqual(testCase.failures(in: "  Do you want lunch?\n"), [])
            expectEqual(testCase.failures(in: "- do you want some lunch.").count, 5)
        }

        test("reports a missing alternative") {
            let testCase = EvalCase(id: "a", group: "g", input: "x", mustContainAny: [["three", "3"]])
            expectEqual(testCase.failures(in: "At two."), ["missing one of [\"three\", \"3\"]"])
        }

        test("builds a pipeline context with defaults") {
            expectEqual(EvalCase(id: "a", group: "g", input: "x").context, PipelineContext())
            let custom = EvalCase(
                id: "a", group: "g", input: "x",
                level: .off, category: .chat, midSentence: true,
                terms: ["Lucid"], replacements: [Replacement(from: "jon", to: "John")]
            )
            let expected = PipelineContext(
                level: .off,
                category: .chat,
                dictionary: PersonalDictionary(terms: ["Lucid"], replacements: [Replacement(from: "jon", to: "John")]),
                midSentence: true
            )
            expectEqual(custom.context, expected)
        }

        test("decodes from JSON with optional fields missing") {
            let json = #"[{"id": "a", "group": "g", "input": "hello", "mustContain": ["hello"]}]"#
            let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
            expectEqual(cases, [EvalCase(id: "a", group: "g", input: "hello", mustContain: ["hello"])])
        }
    }
}
