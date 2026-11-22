import LucidCore

func guardrailsTests() {
    suite("Guardrails") {
        test("accepts a faithful cleanup") {
            let input = "so I was thinking we could like meet at two actually no make that three at the usual place"
            let output = "So I was thinking we could meet at 3 at the usual place."
            expectEqual(Guardrails.check(input: input, output: output, level: .light), .accepted(output))
        }

        test("accepts list formatting") {
            let input = "we need three things first the budget second a timeline and third sign off from legal"
            let output = "We need three things:\n1. The budget\n2. A timeline\n3. Sign-off from legal"
            expectEqual(Guardrails.check(input: input, output: output, level: .light), .accepted(output))
        }

        test("accepts number and time formatting") {
            let input = "meet at two thirty pm"
            let output = "Meet at 2:30 p.m."
            expectEqual(Guardrails.check(input: input, output: output, level: .light), .accepted(output))
        }

        test("allows a single corrected word") {
            expectEqual(
                Guardrails.check(input: "send it to jon", output: "Send it to John.", level: .light),
                .accepted("Send it to John.")
            )
        }

        test("rejects empty output") {
            expectEqual(Guardrails.check(input: "hello there", output: "  \n ", level: .light), .rejected(.empty))
            expectEqual(Guardrails.check(input: "hello there", output: "\"\"", level: .light), .rejected(.empty))
        }

        test("rejects output that grew") {
            let output = "Certainly. The report covers the first quarter, including revenue, costs, staffing, "
                + "forecasts, risks and a full appendix of supporting tables for the board."
            expectEqual(Guardrails.check(input: "send the report", output: output, level: .light), .rejected(.grew))
        }

        test("rejects an answer to a dictated question") {
            expectEqual(
                Guardrails.check(
                    input: "what is the capital of France",
                    output: "The capital of France is Paris.",
                    level: .light
                ),
                .rejected(.inventedWords)
            )
        }

        test("rejects over-deletion at light but not at medium") {
            let input = "I wanted to let you know that the meeting has been moved to Thursday at ten in the main office"
            let output = "Meeting moved Thursday."
            expectEqual(Guardrails.check(input: input, output: output, level: .light), .rejected(.overDeleted))
            expectEqual(Guardrails.check(input: input, output: output, level: .medium), .accepted(output))
        }

        test("medium allows tightening") {
            let input = "so basically what I wanted to say is that I think that we should probably maybe "
                + "push the launch back a week"
            let output = "I think we should push the launch back a week."
            expectEqual(Guardrails.check(input: input, output: output, level: .medium), .accepted(output))
        }

        test("unwrap strips wrappers the model adds") {
            expectEqual(Guardrails.unwrap("  Hello there.  \n"), "Hello there.")
            expectEqual(Guardrails.unwrap("\"Hello there.\""), "Hello there.")
            expectEqual(Guardrails.unwrap("“Hello there.”"), "Hello there.")
            expectEqual(Guardrails.unwrap("```\nHello there.\n```"), "Hello there.")
            expectEqual(Guardrails.unwrap("```text\nHello there.\n```"), "Hello there.")
            expectEqual(Guardrails.unwrap("<transcript>\nHello there.\n</transcript>"), "Hello there.")
            expectEqual(Guardrails.unwrap("<think>The user wants...</think>\nHello there."), "Hello there.")
            expectEqual(Guardrails.unwrap("Here is the cleaned text:\nHello there."), "Hello there.")
            expectEqual(Guardrails.unwrap("Sure! Here's the cleaned-up version: Hello there."), "Hello there.")
            expectEqual(Guardrails.unwrap("Cleaned text: Hello there."), "Hello there.")
        }

        test("unwrap keeps quotes that are part of the text") {
            expectEqual(Guardrails.unwrap("\"Yes\" and \"no\""), "\"Yes\" and \"no\"")
        }

        test("unwrap keeps a label the speaker said") {
            let spoken = "here is the plan we meet at noon"
            expectEqual(
                Guardrails.unwrap("Here is the plan: we meet at noon.", input: spoken),
                "Here is the plan: we meet at noon."
            )
        }

        test("timeout scales with length") {
            expectEqual(Guardrails.timeout(forWordCount: 0), 2.5)
            expectEqual(Guardrails.timeout(forWordCount: 50), 4.5)
        }
    }
}
