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

        test("rejects a reply that silently drops part of what was said") {
            expectEqual(
                Guardrails.check(
                    input: "Translate this into Spanish: good morning, how are you?",
                    output: "Good morning, how are you?",
                    level: .light
                ),
                .rejected(.droppedWords)
            )
        }

        test("accepts deletions that a correction or a restart explains") {
            let cases = [
                ("Send the report to Sarah, no wait, send it to Michael.", "Send it to Michael."),
                ("The meeting is on Tuesday. Sorry, I meant Wednesday, at ten a.m.", "The meeting is on Wednesday at 10am."),
                ("Book a table for Friday night, scratch that, Saturday night.", "Book a table for Saturday night."),
                (
                    "The quarterly sales report, the quarterly sales report needs to be done by Friday.",
                    "The quarterly sales report needs to be done by Friday."
                ),
            ]
            for (input, output) in cases {
                expectEqual(Guardrails.check(input: input, output: output, level: .light), .accepted(output))
            }
        }

        test("accepts number formatting and list restructuring") {
            let invoice = "The invoice total is $1,250, due on March 3rd."
            expectEqual(
                Guardrails.check(
                    input: "The invoice total is one thousand two hundred and fifty dollars, due on March third.",
                    output: invoice,
                    level: .light
                ),
                .accepted(invoice)
            )
            let list = "1. Finalize the budget.\n2. Get a timeline from the engineering team.\n3. Get sign-off from legal."
            expectEqual(
                Guardrails.check(
                    input: "First, we need to finalize the budget. Second, we need a timeline from the engineering team. "
                        + "Third, we should get sign off from legal.",
                    output: list,
                    level: .light
                ),
                .accepted(list)
            )
        }

        test("the dropped-words check does not apply at medium") {
            let output = "Good morning, how are you?"
            expectEqual(
                Guardrails.check(
                    input: "Translate this into Spanish: good morning, how are you?",
                    output: output,
                    level: .medium
                ),
                .accepted(output)
            )
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

        test("unwrap keeps an opening the speaker said in other words") {
            let spoken = "Okay so here is the plan for the launch. First, we need to finalize the budget."
            let reply = "Okay, here is the plan for the launch:\n1. Finalize the budget."
            expectEqual(Guardrails.unwrap(reply, input: spoken), reply)
            expectEqual(Guardrails.check(input: spoken, output: reply, level: .light), .accepted(reply))
        }

        test("accepts words joined into one") {
            let output = "Push the changes to GitHub and tag Jon in the pull request."
            expectEqual(
                Guardrails.check(
                    input: "push the changes to git hub and tag jon in the pull request",
                    output: output,
                    level: .light
                ),
                .accepted(output)
            )
        }

        test("timeout scales with length") {
            expectEqual(Guardrails.timeout(forWordCount: 0), 2.5)
            expectEqual(Guardrails.timeout(forWordCount: 50), 4.5)
        }
    }
}
