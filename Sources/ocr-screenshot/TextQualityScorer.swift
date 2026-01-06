import AppKit

enum TextQualityScorer {
    static func score(_ text: String) -> Double {
        let words = extractWords(from: text)
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

    private static func extractWords(from text: String) -> [String] {
        let pattern = "[A-Za-z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
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
