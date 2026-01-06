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
                lines[index].minX = min(lines[index].minX, box.rect.minX)
            } else {
                lines.append(TextLine(centerY: box.rect.midY, boxes: [box], minX: box.rect.minX))
            }
        }

        lines.sort { $0.centerY > $1.centerY }

        let avgCharWidth = medianCharacterWidth(from: boxes) ?? 7.0
        let baseLeft = lines.map(\.minX).min() ?? 0
        let indentLevels = indentLevels(from: lines, baseLeft: baseLeft, avgCharWidth: avgCharWidth)
        let indentMap = normalizedIndentMap(for: indentLevels)
        if tableFormattingEnabled(),
           let table = formatTable(lines: lines, avgCharWidth: avgCharWidth, medianHeight: medianHeight) {
            return table
        }
        if tableFormattingEnabled(),
           let mixed = formatTablesWithinLines(
               lines: lines,
               avgCharWidth: avgCharWidth,
               medianHeight: medianHeight,
               baseLeft: baseLeft,
               indentLevels: indentLevels,
               indentMap: indentMap
           ) {
            return mixed
        }
        return renderPlainLines(
            lines,
            baseLeft: baseLeft,
            avgCharWidth: avgCharWidth,
            indentLevels: indentLevels,
            indentMap: indentMap
        ).joined(separator: "\n")
    }

    private func renderPlainLines(
        _ lines: [TextLine],
        baseLeft: CGFloat,
        avgCharWidth: CGFloat,
        indentLevels: [Int],
        indentMap: [Int: Int]
    ) -> [String] {
        var renderedLines: [String] = []
        renderedLines.reserveCapacity(lines.count)

        for line in lines {
            let lineCharWidth = medianCharacterWidth(from: line.boxes) ?? avgCharWidth
            let rawLine = renderLine(line, avgCharWidth: avgCharWidth, lineCharWidth: lineCharWidth)
            let indentSpaces = normalizedIndent(
                lineMinX: line.minX,
                baseLeft: baseLeft,
                avgCharWidth: avgCharWidth,
                indentLevels: indentLevels,
                indentMap: indentMap
            )
            let segments = splitOptionMarkers(in: rawLine)
            for segment in segments {
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let prefix = String(repeating: " ", count: indentSpaces)
                renderedLines.append(prefix + trimmed)
            }
        }
        return renderedLines
    }

    private func formatTable(lines: [TextLine], avgCharWidth: CGFloat, medianHeight: CGFloat) -> String? {
        guard !lines.isEmpty else { return nil }
        if let table = formatTableByCellGaps(lines: lines, avgCharWidth: avgCharWidth, medianHeight: medianHeight) {
            return table
        }
        return formatTableByAnchors(lines: lines, avgCharWidth: avgCharWidth, medianHeight: medianHeight)
    }

    private func formatTableByCellGaps(
        lines: [TextLine],
        avgCharWidth: CGFloat,
        medianHeight: CGFloat
    ) -> String? {
        let cellGapThreshold = max(avgCharWidth * 2.25, medianHeight * 0.55, 12.0)
        var rows: [TableRow] = []
        rows.reserveCapacity(lines.count)

        for line in lines {
            let lineCharWidth = medianCharacterWidth(from: line.boxes) ?? avgCharWidth
            let row = buildTableRow(
                line,
                avgCharWidth: avgCharWidth,
                lineCharWidth: lineCharWidth,
                cellGapThreshold: cellGapThreshold
            )
            if !row.cells.isEmpty {
                rows.append(row)
            }
        }

        let candidateRows = rows.filter { $0.cells.count >= 2 }
        let minRowCount = max(2, Int(round(Double(rows.count) * 0.6)))
        guard candidateRows.count >= minRowCount else { return nil }

        let anchorTolerance = max(avgCharWidth * 1.6, medianHeight * 0.5, 8.0)
        let anchors = clusterPositions(
            candidateRows.flatMap { $0.cells.map(\.minX) },
            tolerance: anchorTolerance
        )
        guard anchors.count >= 2 else { return nil }

        let alignment = alignmentRatio(rows: candidateRows, anchors: anchors, tolerance: anchorTolerance)
        guard alignment >= 0.8 else { return nil }

        return renderTable(rows: rows, anchors: anchors, tolerance: anchorTolerance)
    }

    private func formatTableByAnchors(
        lines: [TextLine],
        avgCharWidth: CGFloat,
        medianHeight: CGFloat
    ) -> String? {
        let rowCount = lines.count
        guard rowCount >= 2 else { return nil }
        let anchorTolerance = max(avgCharWidth * 1.4, medianHeight * 0.45, 6.0)
        let anchors = columnAnchors(lines: lines, tolerance: anchorTolerance)
        let minAnchorRows = max(2, Int(round(Double(rowCount) * 0.4)))
        let filteredAnchors = anchors.filter { $0.rows.count >= minAnchorRows }.sorted { $0.center < $1.center }
        let maxColumns = 6
        guard filteredAnchors.count >= 2, filteredAnchors.count <= maxColumns else { return nil }

        let minRowCount = max(2, Int(round(Double(rowCount) * 0.5)))
        var rowsWithColumns = 0
        var tableRows: [[String]] = []
        tableRows.reserveCapacity(lines.count)

        for line in lines {
            let row = renderAnchoredRow(
                boxes: line.boxes,
                anchors: filteredAnchors,
                tolerance: anchorTolerance,
                avgCharWidth: avgCharWidth
            )
            if row.filter({ !$0.isEmpty }).count >= 2 {
                rowsWithColumns += 1
            }
            tableRows.append(row)
        }

        guard rowsWithColumns >= minRowCount else { return nil }
        return renderTableRows(tableRows)
    }

    private func formatTablesWithinLines(
        lines: [TextLine],
        avgCharWidth: CGFloat,
        medianHeight: CGFloat,
        baseLeft: CGFloat,
        indentLevels: [Int],
        indentMap: [Int: Int]
    ) -> String? {
        let segments = tableSegments(lines: lines, avgCharWidth: avgCharWidth, medianHeight: medianHeight)
        guard !segments.isEmpty else { return nil }

        var rendered: [String] = []
        var cursor = 0

        for segment in segments {
            if cursor < segment.start {
                let slice = Array(lines[cursor..<segment.start])
                rendered.append(contentsOf: renderPlainLines(
                    slice,
                    baseLeft: baseLeft,
                    avgCharWidth: avgCharWidth,
                    indentLevels: indentLevels,
                    indentMap: indentMap
                ))
            }

            let tableSlice = Array(lines[segment.start...segment.end])
            if let table = formatTableByCellGaps(
                lines: tableSlice,
                avgCharWidth: avgCharWidth,
                medianHeight: medianHeight
            ) ?? formatTableByAnchors(
                lines: tableSlice,
                avgCharWidth: avgCharWidth,
                medianHeight: medianHeight
            ) {
                rendered.append(table)
            } else {
                rendered.append(contentsOf: renderPlainLines(
                    tableSlice,
                    baseLeft: baseLeft,
                    avgCharWidth: avgCharWidth,
                    indentLevels: indentLevels,
                    indentMap: indentMap
                ))
            }

            cursor = segment.end + 1
        }

        if cursor < lines.count {
            let slice = Array(lines[cursor..<lines.count])
            rendered.append(contentsOf: renderPlainLines(
                slice,
                baseLeft: baseLeft,
                avgCharWidth: avgCharWidth,
                indentLevels: indentLevels,
                indentMap: indentMap
            ))
        }

        return rendered.joined(separator: "\n")
    }

    private func tableSegments(
        lines: [TextLine],
        avgCharWidth: CGFloat,
        medianHeight: CGFloat
    ) -> [TableSegment] {
        let anchorTolerance = max(avgCharWidth * 1.4, medianHeight * 0.45, 6.0)
        let anchors = columnAnchors(lines: lines, tolerance: anchorTolerance)
        if anchors.count >= 3 {
            let segments = tableSegmentsByAnchors(lines: lines, anchors: anchors, tolerance: anchorTolerance)
            if !segments.isEmpty {
                return segments
            }
        }

        return tableSegmentsByGaps(lines: lines, avgCharWidth: avgCharWidth, medianHeight: medianHeight)
    }

    private func tableSegmentsByAnchors(
        lines: [TextLine],
        anchors: [ColumnAnchor],
        tolerance: CGFloat
    ) -> [TableSegment] {
        let farIndex = min(2, max(0, anchors.count - 1))
        var segments: [TableSegment] = []
        var start: Int?
        var lastSignal: Int?
        var strongCount = 0
        var gapCount = 0
        let gapAllowance = 2

        for index in 0..<lines.count {
            let indices = anchorIndices(for: lines[index], anchors: anchors, tolerance: tolerance)
            let hasFarAnchor = indices.contains(where: { $0 >= farIndex })
            let strong = indices.count >= 3 || (indices.count >= 2 && hasFarAnchor)
            let weak = indices.count >= 2 || hasFarAnchor

            if strong {
                if start == nil {
                    start = index
                    strongCount = 0
                }
                strongCount += 1
                lastSignal = index
                gapCount = 0
            } else if start != nil, weak {
                lastSignal = index
                gapCount = 0
            } else if start != nil {
                gapCount += 1
                if gapCount > gapAllowance {
                    if let start, let lastSignal, lastSignal - start + 1 >= 2, strongCount >= 1 {
                        segments.append(TableSegment(start: start, end: lastSignal))
                    }
                    start = nil
                    lastSignal = nil
                    strongCount = 0
                    gapCount = 0
                }
            }
        }

        if let start, let lastSignal, lastSignal - start + 1 >= 2, strongCount >= 1 {
            segments.append(TableSegment(start: start, end: lastSignal))
        }

        return segments
    }

    private func tableSegmentsByGaps(
        lines: [TextLine],
        avgCharWidth: CGFloat,
        medianHeight: CGFloat
    ) -> [TableSegment] {
        var segments: [TableSegment] = []
        var start: Int?
        var lastTableIndex: Int?
        var gapCount = 0
        let gapAllowance = 1

        for index in 0..<lines.count {
            let isTableLine = lineHasColumns(lines[index], avgCharWidth: avgCharWidth, medianHeight: medianHeight)
            if isTableLine {
                if start == nil {
                    start = index
                }
                lastTableIndex = index
                gapCount = 0
            } else if start != nil {
                gapCount += 1
                if gapCount > gapAllowance {
                    if let start, let lastTableIndex, lastTableIndex - start + 1 >= 2 {
                        segments.append(TableSegment(start: start, end: lastTableIndex))
                    }
                    start = nil
                    lastTableIndex = nil
                    gapCount = 0
                }
            }
        }

        if let start, let lastTableIndex, lastTableIndex - start + 1 >= 2 {
            segments.append(TableSegment(start: start, end: lastTableIndex))
        }

        return segments
    }

    private func anchorIndices(
        for line: TextLine,
        anchors: [ColumnAnchor],
        tolerance: CGFloat
    ) -> Set<Int> {
        var indices = Set<Int>()
        for box in line.boxes {
            if let index = nearestAnchorIndex(for: box.rect.minX, anchors: anchors, tolerance: tolerance) {
                indices.insert(index)
            }
        }
        return indices
    }

    private func lineHasColumns(
        _ line: TextLine,
        avgCharWidth: CGFloat,
        medianHeight: CGFloat
    ) -> Bool {
        let sorted = line.boxes.sorted { $0.rect.minX < $1.rect.minX }
        guard sorted.count >= 2 else { return false }

        var gaps: [CGFloat] = []
        var lastMaxX: CGFloat?
        for box in sorted {
            if let lastMaxX {
                let gap = box.rect.minX - lastMaxX
                if gap > 0 {
                    gaps.append(gap)
                }
            }
            lastMaxX = box.rect.maxX
        }
        guard !gaps.isEmpty else { return false }

        let medianGap = median(gaps) ?? 0
        let maxGap = gaps.max() ?? 0
        let threshold = max(avgCharWidth * 1.2, medianHeight * 0.35, 6.0)
        guard maxGap >= threshold else { return false }
        guard medianGap > 0 else { return true }
        return maxGap >= medianGap * 2.0
    }

    private func buildTableRow(
        _ line: TextLine,
        avgCharWidth: CGFloat,
        lineCharWidth: CGFloat,
        cellGapThreshold: CGFloat
    ) -> TableRow {
        let sorted = line.boxes.sorted { $0.rect.minX < $1.rect.minX }
        var cells: [TableCell] = []
        var currentText = ""
        var currentMinX: CGFloat = 0
        var currentMaxX: CGFloat = 0
        var previousCharWidth = lineCharWidth
        var lastMaxX: CGFloat?

        for box in sorted {
            let cleaned = normalizeBoxText(box.text)
            if cleaned.isEmpty { continue }
            let boxCharWidth = max(1.0, box.rect.width / CGFloat(max(1, cleaned.count)))
            let spacingUnit = max(1.0, min(avgCharWidth, lineCharWidth, boxCharWidth, previousCharWidth))
            let gap = lastMaxX.map { box.rect.minX - $0 } ?? 0
            let isNewCell = !currentText.isEmpty && gap >= cellGapThreshold

            if currentText.isEmpty || isNewCell {
                if !currentText.isEmpty {
                    let trimmed = trimTrailingSpaces(currentText).trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        cells.append(TableCell(text: trimmed, minX: currentMinX, maxX: currentMaxX))
                    }
                }
                currentText = cleaned
                currentMinX = box.rect.minX
                currentMaxX = box.rect.maxX
            } else {
                if shouldInsertSpace(
                    output: currentText,
                    cleaned: cleaned,
                    gap: gap,
                    spacingUnit: spacingUnit,
                    boxCharWidth: boxCharWidth,
                    isFirst: false
                ) {
                    currentText.append(" ")
                }
                currentText.append(cleaned)
                currentMaxX = box.rect.maxX
            }

            lastMaxX = box.rect.maxX
            previousCharWidth = boxCharWidth
        }

        let trimmed = trimTrailingSpaces(currentText).trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            cells.append(TableCell(text: trimmed, minX: currentMinX, maxX: currentMaxX))
        }

        let minX = cells.first?.minX ?? line.minX
        let maxX = cells.last?.maxX ?? line.minX
        return TableRow(centerY: line.centerY, minX: minX, maxX: maxX, cells: cells)
    }

    private func clusterPositions(_ positions: [CGFloat], tolerance: CGFloat) -> [CGFloat] {
        guard !positions.isEmpty else { return [] }
        let sorted = positions.sorted()
        var clusters: [(center: CGFloat, count: Int)] = []
        for value in sorted {
            if let last = clusters.last, abs(value - last.center) <= tolerance {
                let newCount = last.count + 1
                let newCenter = (last.center * CGFloat(last.count) + value) / CGFloat(newCount)
                clusters[clusters.count - 1] = (center: newCenter, count: newCount)
            } else {
                clusters.append((center: value, count: 1))
            }
        }
        return clusters.map { $0.center }
    }

    private func alignmentRatio(rows: [TableRow], anchors: [CGFloat], tolerance: CGFloat) -> Double {
        var aligned = 0
        var total = 0
        for row in rows {
            for cell in row.cells {
                total += 1
                if nearestAnchorIndex(for: cell.minX, anchors: anchors, tolerance: tolerance) != nil {
                    aligned += 1
                }
            }
        }
        guard total > 0 else { return 0 }
        return Double(aligned) / Double(total)
    }

    private func nearestAnchorIndex(for value: CGFloat, anchors: [CGFloat], tolerance: CGFloat) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, anchor) in anchors.enumerated() {
            let distance = abs(value - anchor)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard bestDistance <= tolerance else { return nil }
        return bestIndex
    }

    private func nearestAnchorIndex(for value: CGFloat, anchors: [ColumnAnchor], tolerance: CGFloat) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, anchor) in anchors.enumerated() {
            let distance = abs(value - anchor.center)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard bestDistance <= tolerance else { return nil }
        return bestIndex
    }

    private func renderTable(rows: [TableRow], anchors: [CGFloat], tolerance: CGFloat) -> String {
        let columnCount = anchors.count
        var tableRows: [[String]] = []
        tableRows.reserveCapacity(rows.count)

        for row in rows {
            var cells = Array(repeating: "", count: columnCount)
            for cell in row.cells {
                let index = nearestAnchorIndex(for: cell.minX, anchors: anchors, tolerance: tolerance)
                    ?? nearestAnchorIndex(for: cell.minX, anchors: anchors, tolerance: .greatestFiniteMagnitude)
                    ?? 0
                if cells[index].isEmpty {
                    cells[index] = cell.text
                } else {
                    cells[index] += " " + cell.text
                }
            }
            tableRows.append(cells.map { $0.trimmingCharacters(in: .whitespaces) })
        }

        var widths = Array(repeating: 1, count: columnCount)
        for row in tableRows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }

        var rendered: [String] = []
        rendered.reserveCapacity(tableRows.count + 1)
        for (index, row) in tableRows.enumerated() {
            rendered.append(renderTableRow(row, widths: widths))
            if index == 0, markdownTableEnabled() {
                rendered.append(renderTableSeparator(widths: widths))
            }
        }
        return rendered.joined(separator: "\n")
    }

    private func renderTableRows(_ rows: [[String]]) -> String {
        guard let columnCount = rows.first?.count, columnCount > 0 else { return "" }
        var widths = Array(repeating: 1, count: columnCount)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], cell.count)
            }
        }

        var rendered: [String] = []
        rendered.reserveCapacity(rows.count + 1)
        for (index, row) in rows.enumerated() {
            rendered.append(renderTableRow(row, widths: widths))
            if index == 0, markdownTableEnabled() {
                rendered.append(renderTableSeparator(widths: widths))
            }
        }
        return rendered.joined(separator: "\n")
    }

    private func renderTableRow(_ row: [String], widths: [Int]) -> String {
        var cells: [String] = []
        cells.reserveCapacity(row.count)
        for (index, cell) in row.enumerated() {
            let padding = max(0, widths[index] - cell.count)
            let padded = " " + cell + String(repeating: " ", count: padding) + " "
            cells.append(padded)
        }
        return "|" + cells.joined(separator: "|") + "|"
    }

    private func renderTableSeparator(widths: [Int]) -> String {
        var cells: [String] = []
        cells.reserveCapacity(widths.count)
        for width in widths {
            let dashCount = max(3, width)
            let cell = " " + String(repeating: "-", count: dashCount) + " "
            cells.append(cell)
        }
        return "|" + cells.joined(separator: "|") + "|"
    }

    private func tableFormattingEnabled() -> Bool {
        ProcessInfo.processInfo.environment["OCR_TABLE_FORMAT"] != "0"
    }

    private func markdownTableEnabled() -> Bool {
        ProcessInfo.processInfo.environment["OCR_TABLE_MARKDOWN"] != "0"
    }

    private func renderAnchoredRow(
        boxes: [RecognizedTextBox],
        anchors: [ColumnAnchor],
        tolerance: CGFloat,
        avgCharWidth: CGFloat
    ) -> [String] {
        let columnCount = anchors.count
        var columnBoxes = Array(repeating: [RecognizedTextBox](), count: columnCount)
        for box in boxes.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            let index = nearestAnchorIndex(for: box.rect.minX, anchors: anchors, tolerance: tolerance)
                ?? nearestAnchorIndex(for: box.rect.minX, anchors: anchors, tolerance: .greatestFiniteMagnitude)
                ?? 0
            columnBoxes[index].append(box)
        }

        return columnBoxes.map { boxes in
            guard !boxes.isEmpty else { return "" }
            let minX = boxes.map(\.rect.minX).min() ?? 0
            let line = TextLine(centerY: 0, boxes: boxes, minX: minX)
            let lineCharWidth = medianCharacterWidth(from: boxes) ?? avgCharWidth
            return renderLine(line, avgCharWidth: avgCharWidth, lineCharWidth: lineCharWidth)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private func renderLine(_ line: TextLine, avgCharWidth: CGFloat, lineCharWidth: CGFloat) -> String {
        let sorted = line.boxes.sorted { $0.rect.minX < $1.rect.minX }
        var output = ""
        var previousCharWidth = lineCharWidth
        var lastMaxX: CGFloat?

        for (index, box) in sorted.enumerated() {
            let cleaned = normalizeBoxText(box.text)
            if cleaned.isEmpty { continue }
            let boxCharWidth = max(1.0, box.rect.width / CGFloat(max(1, cleaned.count)))
            let spacingUnit = max(1.0, min(avgCharWidth, lineCharWidth, boxCharWidth, previousCharWidth))
            let gap = lastMaxX.map { box.rect.minX - $0 } ?? 0
            if shouldInsertSpace(
                output: output,
                cleaned: cleaned,
                gap: gap,
                spacingUnit: spacingUnit,
                boxCharWidth: boxCharWidth,
                isFirst: index == 0
            ) {
                output.append(" ")
            }
            output.append(cleaned)
            lastMaxX = box.rect.maxX
            previousCharWidth = boxCharWidth
        }

        return trimTrailingSpaces(output)
    }

    private func shouldInsertSpace(
        output: String,
        cleaned: String,
        gap: CGFloat,
        spacingUnit: CGFloat,
        boxCharWidth: CGFloat,
        isFirst: Bool
    ) -> Bool {
        guard !isFirst else { return false }
        guard !output.isEmpty else { return false }
        guard output.last?.isWhitespace == false else { return false }

        let looksLikeGlyph = cleaned.count == 1 && boxCharWidth < spacingUnit * 0.7
        if looksLikeGlyph {
            return gap > spacingUnit * 0.6
        }

        if gap >= spacingUnit * 0.15 {
            return true
        }

        if let lastChar = output.last, let firstChar = cleaned.first {
            if lastChar.isLetter || lastChar.isNumber {
                if firstChar.isLetter || firstChar.isNumber {
                    return true
                }
            }
        }

        return false
    }

    private func normalizeBoxText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed
    }

    private func columnAnchors(lines: [TextLine], tolerance: CGFloat) -> [ColumnAnchor] {
        var anchors: [ColumnAnchor] = []
        for (rowIndex, line) in lines.enumerated() {
            for box in line.boxes {
                let x = box.rect.minX
                if let index = nearestAnchorIndex(for: x, anchors: anchors, tolerance: tolerance) {
                    var anchor = anchors[index]
                    let newCount = anchor.count + 1
                    let newCenter = (anchor.center * CGFloat(anchor.count) + x) / CGFloat(newCount)
                    anchor.center = newCenter
                    anchor.count = newCount
                    anchor.rows.insert(rowIndex)
                    anchors[index] = anchor
                } else {
                    anchors.append(ColumnAnchor(center: x, count: 1, rows: [rowIndex]))
                }
            }
        }
        return anchors.sorted { $0.center < $1.center }
    }

    private func indentLevels(from lines: [TextLine], baseLeft: CGFloat, avgCharWidth: CGFloat) -> [Int] {
        guard avgCharWidth > 0 else { return [0] }
        let rawLevels = lines.map { line -> Int in
            let offset = max(0, line.minX - baseLeft)
            let units = Int(round(offset / avgCharWidth))
            return units < 1 ? 0 : units
        }.sorted()

        var levels: [Int] = []
        for value in rawLevels {
            if let last = levels.last, abs(value - last) <= 2 {
                continue
            }
            levels.append(value)
        }
        if levels.isEmpty {
            return [0]
        }
        return levels
    }

    private func normalizedIndentMap(for indentLevels: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (index, level) in indentLevels.enumerated() {
            map[level] = index * 2
        }
        return map
    }

    private func normalizedIndent(
        lineMinX: CGFloat,
        baseLeft: CGFloat,
        avgCharWidth: CGFloat,
        indentLevels: [Int],
        indentMap: [Int: Int]
    ) -> Int {
        guard avgCharWidth > 0 else { return 0 }
        let offset = max(0, lineMinX - baseLeft)
        let units = Int(round(offset / avgCharWidth))
        let clamped = units < 1 ? 0 : units
        let nearest = indentLevels.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? 0
        return indentMap[nearest] ?? 0
    }

    private func splitOptionMarkers(in line: String) -> [String] {
        let pattern = "(?:^|\\s)([A-H]|\\d{1,2})\\."
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [line]
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard matches.count > 1 else { return [line] }

        var starts: [String.Index] = []
        starts.reserveCapacity(matches.count)
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            if let range = Range(match.range(at: 1), in: line) {
                starts.append(range.lowerBound)
            }
        }
        guard starts.count > 1 else { return [line] }

        var segments: [String] = []
        for index in 0..<starts.count {
            let start = starts[index]
            let end = (index + 1 < starts.count) ? starts[index + 1] : line.endIndex
            let segment = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty {
                segments.append(segment)
            }
        }
        return segments.isEmpty ? [line] : segments
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
    var minX: CGFloat
}

private struct TableCell {
    var text: String
    var minX: CGFloat
    var maxX: CGFloat
}

private struct TableRow {
    var centerY: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    var cells: [TableCell]
}

private struct ColumnAnchor {
    var center: CGFloat
    var count: Int
    var rows: Set<Int>
}

private struct TableSegment {
    var start: Int
    var end: Int
}
