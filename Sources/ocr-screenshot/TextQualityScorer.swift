import AppKit

enum TextQualityScorer {
    private static let maxWordCount = 120

    static func score(_ text: String) -> Double {
        let words = extractWords(from: text, limit: maxWordCount)
        guard !words.isEmpty else { return 0.0 }

        let checker = NSSpellChecker.shared
        var valid = 0
        var total = 0
        for word in words where word.count >= 3 {
            total += 1
            let range = checker.checkSpelling(of: word, startingAt: 0)
            if range.location == NSNotFound {
                valid += 1
            }
        }

        let validRatio = total > 0 ? Double(valid) / Double(total) : 0.0
        let asciiRatio = asciiLetterRatio(in: text)
        return (validRatio * 0.85) + (asciiRatio * 0.15)
    }

    static func chooseBetter(primary: String, secondary: String) -> String {
        let primaryScore = score(primary)
        let secondaryScore = score(secondary)
        if secondaryScore > primaryScore + 0.05 {
            return secondary
        }
        if primaryScore > secondaryScore + 0.05 {
            return primary
        }
        if secondary.count > primary.count {
            return secondary
        }
        return primary
    }

    static func chooseBetter(primary: String, primaryScore: Double, secondary: String) -> (text: String, score: Double) {
        let secondaryScore = score(secondary)
        if secondaryScore > primaryScore + 0.05 {
            return (secondary, secondaryScore)
        }
        if primaryScore > secondaryScore + 0.05 {
            return (primary, primaryScore)
        }
        if secondary.count > primary.count {
            return (secondary, secondaryScore)
        }
        return (primary, primaryScore)
    }

    private static func extractWords(from text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var words: [String] = []
        words.reserveCapacity(min(24, limit))
        var buffer = ""
        buffer.reserveCapacity(16)

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAsciiLetter = (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
            if isAsciiLetter {
                buffer.unicodeScalars.append(scalar)
            } else if buffer.count >= 2 {
                words.append(buffer)
                if words.count >= limit {
                    return words
                }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if buffer.count >= 2 {
            words.append(buffer)
        }

        return words.count > limit ? Array(words.prefix(limit)) : words
    }

    private static func asciiLetterRatio(in text: String) -> Double {
        var letters = 0
        var asciiLetters = 0
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            letters += 1
            if scalar.isASCII {
                asciiLetters += 1
            }
        }
        guard letters > 0 else { return 0.0 }
        return Double(asciiLetters) / Double(letters)
    }
}
