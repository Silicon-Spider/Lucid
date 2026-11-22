import LucidCore

func harnessTests() {
    suite("Harness") {
        test("equal values pass") {
            expectEqual(1 + 1, 2)
            expectTrue(CleanupLevel.allCases.count == 3)
            expectFalse(AppCategory.allCases.isEmpty)
        }
    }
}
