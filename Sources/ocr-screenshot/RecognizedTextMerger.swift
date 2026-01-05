import CoreGraphics

enum RecognizedTextMerger {
    static func merge(primary: [RecognizedTextBox], secondary: [RecognizedTextBox]) -> [RecognizedTextBox] {
        guard !secondary.isEmpty else { return primary }
        var merged = primary

        for candidate in secondary {
            if let index = bestOverlapIndex(for: candidate, in: merged) {
                let primaryBox = merged[index]
                let primaryScore = textScore(primaryBox.text)
                let secondaryScore = textScore(candidate.text)
                let rect = primaryBox.rect.union(candidate.rect)
                if secondaryScore > primaryScore {
                    merged[index] = RecognizedTextBox(text: candidate.text, rect: rect)
                } else {
                    merged[index] = RecognizedTextBox(text: primaryBox.text, rect: rect)
                }
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

    private static func textScore(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}
