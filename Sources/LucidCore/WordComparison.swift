import Foundation

/// Word-level comparison used by the guardrails and the pipeline.
enum WordComparison {
    /// "p.m." and "e.g." written with dots.
    private static let dottedLetters = TextUtil.regex(#"\b([a-z])\.([a-z])\.?"#)

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6",
        "seventh": "7", "eighth": "8", "ninth": "9", "tenth": "10",
    ]

    /// Lower-cased words with punctuation removed. Number words and ordinals become digits,
    /// and "p.m." becomes "pm", so that formatting changes do not count as different words.
    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let joined = TextUtil.replace(dottedLetters, in: lowered, with: "$1$2")

        var words: [String] = []
        var current = ""
        for character in joined {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        return words.compactMap { word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if trimmed.isEmpty { return nil }
            return numberWords[trimmed] ?? trimmed
        }
    }

    /// Length of the longest common subsequence of two word lists.
    static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for wordA in a {
            for (index, wordB) in b.enumerated() {
                current[index + 1] = wordA == wordB
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// For each word of `a`, whether it belongs to a longest common subsequence with `b`.
    /// The words marked false are the ones that were deleted to get from `a` to `b`.
    static func matchedFlags(_ a: [String], _ b: [String]) -> [Bool] {
        var flags = [Bool](repeating: false, count: a.count)
        guard !a.isEmpty, !b.isEmpty else { return flags }

        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i * width + j] = a[i - 1] == b[j - 1]
                    ? table[(i - 1) * width + (j - 1)] + 1
                    : max(table[(i - 1) * width + j], table[i * width + (j - 1)])
            }
        }

        var i = a.count
        var j = b.count
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                flags[i - 1] = true
                i -= 1
                j -= 1
            } else if table[(i - 1) * width + j] >= table[i * width + (j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return flags
    }
}
