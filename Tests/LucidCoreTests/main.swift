import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()

TestRun.shared.finish()
