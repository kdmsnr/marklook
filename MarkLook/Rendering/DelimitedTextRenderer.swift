import Foundation

struct DelimitedTextRenderer {
    func render(
        _ source: String,
        delimiter: Unicode.Scalar,
        context: RenderContext
    ) throws -> RenderOutput {
        let clock = ContinuousClock()
        let parsingStarted = clock.now
        let parsed = try DelimitedTextParser().parse(source, delimiter: delimiter)
        let parsing = parsingStarted.duration(to: clock.now)
        let formattingStarted = clock.now
        let columnCount = parsed.rows.map(\.count).max() ?? 0
        let rowCount = max(0, parsed.rows.count - 1)
        var warnings: [RenderWarning] = []
        if parsed.isTruncated {
            warnings.append(RenderWarning(
                id: "delimited-preview-limit",
                message: "Showing the first \(rowCount) data rows. The table preview is limited to 10,000 data rows or 100,000 cells, including the header. Search and PDF export include only this preview."
            ))
        }

        var html = "<section class=\"delimited-document\" aria-label=\"Table document\">"
        if let header = parsed.rows.first {
            let prefix = parsed.isTruncated ? "Preview · " : ""
            html += "<div class=\"delimited-summary\">\(prefix)\(rowCount) \(rowCount == 1 ? "row" : "rows") · \(columnCount) \(columnCount == 1 ? "column" : "columns")<span>First row is the header · Click a column to sort</span></div>"
            html += "<div class=\"delimited-viewport\" role=\"region\" aria-label=\"Scrollable table\" tabindex=\"0\">"
            html += "<table class=\"delimited-table\" aria-label=\"\(HTMLEscaping.attribute(context.documentURL.lastPathComponent))\"><thead><tr><th class=\"delimited-row-number\" scope=\"col\" aria-label=\"Row number\">#</th>"
            for column in 0..<columnCount {
                let title = column < header.count ? header[column] : ""
                let content = title.isEmpty
                    ? "<span class=\"delimited-placeholder\">Column \(column + 1)</span>"
                    : HTMLEscaping.text(title)
                html += "<th scope=\"col\" aria-sort=\"none\"><button type=\"button\" class=\"delimited-sort\" data-marklook-column=\"\(column)\" title=\"Sort ascending\"><span class=\"delimited-cell\">\(content)</span><span class=\"delimited-sort-indicator\" aria-hidden=\"true\"></span></button></th>"
            }
            html += "</tr></thead><tbody>"
            for (index, row) in parsed.rows.dropFirst().enumerated() {
                html += "<tr data-marklook-row=\"\(index)\"><th class=\"delimited-row-number\" scope=\"row\">\(index + 1)</th>"
                for cell in row {
                    html += "<td><div class=\"delimited-cell\">\(HTMLEscaping.text(cell))</div></td>"
                }
                // A spanning empty cell avoids quadratic HTML growth for ragged records.
                if row.count < columnCount {
                    html += "<td colspan=\"\(columnCount - row.count)\"></td>"
                }
                html += "</tr>"
            }
            html += "</tbody></table></div>"
        } else {
            html += "<p class=\"delimited-empty\">This file has no rows.</p>"
        }
        html += "</section>"

        // Every source value is emitted as escaped text. No source HTML, links, or formulas run.
        return RenderOutput(
            htmlFragment: html,
            title: context.documentURL.lastPathComponent,
            resources: [],
            warnings: warnings,
            containsMath: false,
            sizeClass: context.sizeClass,
            timing: RenderPipelineTiming(
                preprocessing: parsing,
                markdownParsing: .zero,
                markdownFormatting: .zero,
                extensionPostprocessing: .zero,
                htmlParsing: .zero,
                htmlTransforming: .zero,
                htmlCleaning: .zero,
                htmlSerializing: formattingStarted.duration(to: clock.now)
            )
        )
    }
}
