import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()

TestRun.shared.finish()
