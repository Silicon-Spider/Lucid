import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()

TestRun.shared.finish()
