import Foundation

/// Reads CSV and TSV records without splitting quoted delimiters or embedded newlines.
/// The preview budget bounds both parsing allocations and the number of DOM cells.
struct DelimitedTextParser {
    struct Output: Equatable {
        let rows: [[String]]
        let isTruncated: Bool
    }

    private enum FieldState {
        case start, unquoted, quoted, closedQuote
    }

    func parse(
        _ source: String,
        delimiter: Unicode.Scalar,
        maximumRows: Int = 10_001,
        maximumCells: Int = 100_000
    ) throws -> Output {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var state = FieldState.start
        var cellCount = 0
        var hasRecord = false
        var skipLineFeed = false

        func truncatedOutput() throws -> Output {
            guard !rows.isEmpty else {
                throw DocumentLoadError.renderingFailed("The first record exceeds the table preview cell limit.")
            }
            return Output(rows: rows, isTruncated: true)
        }

        func finishField() {
            row.append(field)
            field = ""
            cellCount += 1
            state = .start
        }

        for (index, scalar) in source.unicodeScalars.enumerated() {
            if index == 0, scalar == "\u{FEFF}" { continue }
            if skipLineFeed {
                skipLineFeed = false
                if scalar == "\n" { continue }
            }
            if rows.count >= maximumRows || cellCount >= maximumCells {
                return try truncatedOutput()
            }
            hasRecord = true

            if state == .quoted {
                if scalar == "\"" {
                    state = .closedQuote
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if state == .closedQuote, scalar == "\"" {
                field.append("\"")
                state = .quoted
            } else if scalar == delimiter {
                finishField()
            } else if scalar == "\r" || scalar == "\n" {
                finishField()
                rows.append(row)
                row = []
                hasRecord = false
                skipLineFeed = scalar == "\r"
            } else if state == .closedQuote {
                throw DocumentLoadError.renderingFailed(
                    "Unexpected text after a closing quote in record \(rows.count + 1)."
                )
            } else if state == .start, scalar == "\"" {
                state = .quoted
            } else {
                field.unicodeScalars.append(scalar)
                state = .unquoted
            }
        }

        guard state != .quoted else {
            throw DocumentLoadError.renderingFailed("Unclosed quoted field in record \(rows.count + 1).")
        }
        if hasRecord {
            guard cellCount < maximumCells else { return try truncatedOutput() }
            finishField()
            rows.append(row)
        }
        return Output(rows: rows, isTruncated: false)
    }
}
