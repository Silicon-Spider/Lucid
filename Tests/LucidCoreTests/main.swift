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
livePreviewTests()
evalCaseTests()
await engineTests()
clientTests()
dictationMachineTests()
insertionTests()
historyTests()
dictionaryEditingTests()
modelLibraryTests()
await downloadTests()

TestRun.shared.finish()
