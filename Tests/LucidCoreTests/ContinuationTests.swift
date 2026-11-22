import LucidCore

func continuationTests() async {
    await asyncSuite("Continuation") {
        test("lower-cases a safe first word") {
            expectEqual(StyleRules.continuingSentence("And then we can go."), "and then we can go.")
            expectEqual(StyleRules.continuingSentence("The report is ready."), "the report is ready.")
            expectEqual(StyleRules.continuingSentence("Let's go."), "let's go.")
        }

        test("keeps names, I and acronyms") {
            expectEqual(StyleRules.continuingSentence("John agreed."), "John agreed.")
            expectEqual(StyleRules.continuingSentence("I think so."), "I think so.")
            expectEqual(StyleRules.continuingSentence("I'm not sure."), "I'm not sure.")
            expectEqual(StyleRules.continuingSentence("API keys rotate weekly."), "API keys rotate weekly.")
            expectEqual(StyleRules.continuingSentence("already lower."), "already lower.")
            expectEqual(StyleRules.continuingSentence(""), "")
        }

        await asyncTest("the pipeline applies it when the cursor is mid-sentence") {
            let pipeline = Pipeline(cleaner: nil)
            let mid = await pipeline.process("And then we can review it.", context: PipelineContext(midSentence: true))
            expectEqual(mid.finalText, "and then we can review it.")
            let start = await pipeline.process("And then we can review it.", context: PipelineContext(midSentence: false))
            expectEqual(start.finalText, "And then we can review it.")
        }
    }
}
