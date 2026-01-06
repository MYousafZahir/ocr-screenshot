import CoreGraphics

enum RecognizedTextMerger {
    static func merge(primary: [RecognizedTextBox], secondary: [RecognizedTextBox]) -> [RecognizedTextBox] {
        guard !secondary.isEmpty else { return primary }
        var merged = primary

        for candidate in secondary {
            if let index = bestOverlapIndex(for: candidate, in: merged) {
                let primaryBox = merged[index]
                let rect = primaryBox.rect.union(candidate.rect)
                let chosenText = chooseText(primary: primaryBox.text, secondary: candidate.text)
                merged[index] = RecognizedTextBox(text: chosenText, rect: rect)
            } else {
                merged.append(candidate)
            }
        }

        return merged
    }

    private static func bestOverlapIndex(for box: RecognizedTextBox, in boxes: [RecognizedTextBox]) -> Int? {
        var bestIndex: Int?
        var bestScore: CGFloat = 0
        for (index, candidate) in boxes.enumerated() {
            let score = overlapScore(box.rect, candidate.rect)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestScore >= 0.6 ? bestIndex : nil
    }

    private static func overlapScore(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let minArea = min(areaA, areaB)
        guard minArea > 0 else { return 0 }
        return intersectionArea / minArea
    }

    private static func chooseText(primary: String, secondary: String) -> String {
        let primaryNormalized = normalize(primary)
        let secondaryNormalized = normalize(secondary)
        guard !secondaryNormalized.isEmpty else { return primary }
        guard !primaryNormalized.isEmpty else { return secondary }

        if primaryNormalized.count < 3 && secondaryNormalized.count > primaryNormalized.count {
            return secondary
        }

        if secondaryNormalized.contains(primaryNormalized) || primaryNormalized.contains(secondaryNormalized) {
            return secondaryNormalized.count > primaryNormalized.count ? secondary : primary
        }

        let similarity = similarityRatio(primaryNormalized, secondaryNormalized)
        if similarity >= 0.6 && secondaryNormalized.count > primaryNormalized.count {
            return secondary
        }

        return primary
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func similarityRatio(_ a: String, _ b: String) -> Double {
        let minLength = min(a.count, b.count)
        guard minLength > 0 else { return 0 }
        let prefix = commonPrefixLength(a, b)
        let suffix = commonSuffixLength(a, b)
        return Double(prefix + suffix) / Double(minLength)
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let count = min(aChars.count, bChars.count)
        var length = 0
        for index in 0..<count where aChars[index] == bChars[index] {
            length += 1
        }
        return length
    }

    private static func commonSuffixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let count = min(aChars.count, bChars.count)
        var length = 0
        for offset in 0..<count where aChars[aChars.count - 1 - offset] == bChars[bChars.count - 1 - offset] {
            length += 1
        }
        return length
    }
}
