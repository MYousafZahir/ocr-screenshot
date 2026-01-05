import Foundation

struct LayoutFormatter: Sendable {
    func format(boxes: [RecognizedTextBox]) -> String {
        guard !boxes.isEmpty else { return "" }

        let medianHeight = median(boxes.map { $0.rect.height }) ?? 12.0
        let lineThreshold = max(4.0, medianHeight * 0.6)

        var lines: [TextLine] = []
        for box in boxes.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let index = lines.firstIndex(where: { abs($0.centerY - box.rect.midY) <= lineThreshold }) {
                lines[index].boxes.append(box)
                lines[index].centerY = (lines[index].centerY + box.rect.midY) / 2.0
            } else {
                lines.append(TextLine(centerY: box.rect.midY, boxes: [box]))
            }
        }

        lines.sort { $0.centerY > $1.centerY }

        let avgCharWidth = medianCharacterWidth(from: boxes) ?? 7.0
        let renderedLines = lines.map { line in
            let lineCharWidth = medianCharacterWidth(from: line.boxes) ?? avgCharWidth
            return renderLine(line, avgCharWidth: avgCharWidth, lineCharWidth: lineCharWidth)
        }
        return renderedLines.joined(separator: "\n")
    }

    private func renderLine(_ line: TextLine, avgCharWidth: CGFloat, lineCharWidth: CGFloat) -> String {
        let sorted = line.boxes.sorted { $0.rect.minX < $1.rect.minX }
        var output = ""
        var cursorX: CGFloat = 0
        var previousCharWidth = lineCharWidth

        for (index, box) in sorted.enumerated() {
            let targetStart = box.rect.minX
            let boxCharWidth = max(1.0, box.rect.width / CGFloat(max(1, box.text.count)))
            let spacingUnit = max(1.0, min(avgCharWidth, lineCharWidth, boxCharWidth, previousCharWidth))
            let rawSpaces = (targetStart - cursorX) / spacingUnit
            let spaces: Int
            if index == 0 {
                spaces = rawSpaces > 0 ? max(0, Int(ceil(rawSpaces - 0.01))) : 0
            } else {
                spaces = rawSpaces > 0 ? max(1, Int(ceil(rawSpaces - 0.01))) : 0
            }

            if spaces > 0 {
                output.append(String(repeating: " ", count: spaces))
            }
            output.append(box.text)
            cursorX = box.rect.maxX
            previousCharWidth = boxCharWidth
        }

        return trimTrailingSpaces(output)
    }

    private func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func medianCharacterWidth(from boxes: [RecognizedTextBox]) -> CGFloat? {
        var widths: [CGFloat] = []
        widths.reserveCapacity(boxes.count)
        for box in boxes {
            let length = max(1, box.text.count)
            widths.append(box.rect.width / CGFloat(length))
        }
        return median(widths)
    }

    private func trimTrailingSpaces(_ text: String) -> String {
        var output = text
        while output.last == " " {
            output.removeLast()
        }
        return output
    }
}

private struct TextLine {
    var centerY: CGFloat
    var boxes: [RecognizedTextBox]
}
