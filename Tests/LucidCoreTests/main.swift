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

TestRun.shared.finish()
