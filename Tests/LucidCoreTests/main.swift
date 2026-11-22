import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()
whisperWindowTests()
evalCaseTests()
await engineTests()
clientTests()

TestRun.shared.finish()
