import LucidCore

func styleRulesTests() {
    suite("StyleRules") {
        test("maps bundle identifiers to categories") {
            expectEqual(AppCategory.forBundleID("com.apple.mail"), .email)
            expectEqual(AppCategory.forBundleID("COM.APPLE.MAIL"), .email)
            expectEqual(AppCategory.forBundleID("com.tinyspeck.slackmacgap"), .chat)
            expectEqual(AppCategory.forBundleID("com.apple.MobileSMS"), .chat)
            expectEqual(AppCategory.forBundleID("com.apple.Terminal"), .code)
            expectEqual(AppCategory.forBundleID("com.jetbrains.intellij"), .code)
            expectEqual(AppCategory.forBundleID("com.anthropic.claudefordesktop"), .code)
            expectEqual(AppCategory.forBundleID("com.apple.Safari"), .other)
            expectEqual(AppCategory.forBundleID(""), .other)
            expectEqual(AppCategory.forBundleID(nil), .other)
        }

        test("chat drops the final full stop from a short message") {
            expectEqual(StyleRules.apply("See you soon.", category: .chat), "See you soon")
            expectEqual(StyleRules.apply("Running late. See you soon.", category: .chat), "Running late. See you soon")
        }

        test("chat leaves other endings alone") {
            expectEqual(StyleRules.apply("Really?", category: .chat), "Really?")
            expectEqual(StyleRules.apply("Great!", category: .chat), "Great!")
            expectEqual(StyleRules.apply("Wait...", category: .chat), "Wait...")
            expectEqual(StyleRules.apply("See you at 3 p.m.", category: .chat), "See you at 3 p.m.")
            expectEqual(StyleRules.apply("", category: .chat), "")
        }

        test("chat leaves longer messages alone") {
            expectEqual(
                StyleRules.apply("Running late. Traffic is bad. See you soon.", category: .chat),
                "Running late. Traffic is bad. See you soon."
            )
            expectEqual(StyleRules.apply("Two things:\n1. Milk.", category: .chat), "Two things:\n1. Milk.")
        }

        test("other categories are unchanged") {
            for category in [AppCategory.email, .code, .other] {
                expectEqual(StyleRules.apply("See you soon.", category: category), "See you soon.")
            }
        }
    }
}
