import CryptoKit
import Foundation
import Markdown

actor GFMRenderEngine: RenderEngine {
    private let sanitizer = HTMLSanitizer()
    private let preprocessor = MarkupPreprocessor()

    func render(
        source: String,
        format: DocumentFormat,
        context: RenderContext
    ) async throws -> RenderOutput {
        do {
            switch format {
            case .markdown:
                return try renderMarkdown(source, context: context)
            case .html:
                return try renderHTML(source, context: context)
            }
        } catch let error as DocumentLoadError {
            throw error
        } catch {
            throw DocumentLoadError.renderingFailed(error.localizedDescription)
        }
    }

    private func renderMarkdown(_ source: String, context: RenderContext) throws -> RenderOutput {
        let clock = ContinuousClock()
        let preprocessingStartedAt = clock.now
        let processed = preprocessor.process(source)
        let preprocessing = preprocessingStartedAt.duration(to: clock.now)

        let parsingStartedAt = clock.now
        let document = Document(parsing: processed.source)
        let footnoteDocuments = processed.footnotes.map { footnote in
            (footnote, Document(parsing: footnote.source))
        }
        var requiresFullSanitization = containsMeaningfulRawHTML(in: document)
        if !requiresFullSanitization {
            for (_, footnoteDocument) in footnoteDocuments {
                if containsMeaningfulRawHTML(in: footnoteDocument) {
                    requiresFullSanitization = true
                    break
                }
            }
        }
        let markdownParsing = parsingStartedAt.duration(to: clock.now)

        let formattingStartedAt = clock.now
        let estimatedSourceByteCount = processed.source.utf8.count
        let formatted: SecureHTMLFormatter.Output
        if requiresFullSanitization {
            formatted = SecureHTMLFormatter.Output(
                html: SecureHTMLFormatter.format(
                    document,
                    source: processed.source,
                    lineBreakMode: context.markdownLineBreakMode,
                    estimatedSourceByteCount: estimatedSourceByteCount
                ),
                resources: [],
                warnings: []
            )
        } else {
            formatted = SecureHTMLFormatter.format(
                document,
                source: processed.source,
                context: context,
                estimatedSourceByteCount: estimatedSourceByteCount
            )
        }
        var html = formatted.html
        var resources = formatted.resources
        var warnings = formatted.warnings
        let markdownFormatting = formattingStartedAt.duration(to: clock.now)

        let postprocessingStartedAt = clock.now
        for replacement in processed.math {
            let display = replacement.display ? "block" : "inline"
            let element = "<span class=\"marklook-math marklook-math-\(display)\" data-marklook-math=\"true\" data-display=\"\(display)\">\(HTMLEscaping.text(replacement.source))</span>"
            html = html.replacingOccurrences(of: replacement.token, with: element)
        }

        let footnoteAnchorIDs = collisionSafeFootnoteAnchorIDs(for: processed.footnotes)
        var referenceCounts: [String: Int] = [:]
        for referenceReplacement in processed.footnoteReferences {
            let id = referenceReplacement.id
            let index = referenceCounts[id, default: 0] + 1
            referenceCounts[id] = index
            let safeID = footnoteAnchorIDs[id] ?? anchorID(id)
            let referenceID = index == 1 ? "fnref-\(safeID)" : "fnref-\(safeID)-\(index)"
            let reference = "<sup id=\"\(referenceID)\" class=\"footnote-ref\"><a href=\"#fn-\(safeID)\" aria-label=\"Footnote \(HTMLEscaping.attribute(id))\">\(HTMLEscaping.text(id))</a></sup>"
            html = html.replacingOccurrences(of: referenceReplacement.token, with: reference)
        }

        if !processed.footnotes.isEmpty {
            html += "<section class=\"footnotes\" aria-label=\"Footnotes\"><hr><ol>"
            for (footnote, footnoteDocument) in footnoteDocuments {
                let safeID = footnoteAnchorIDs[footnote.id] ?? anchorID(footnote.id)
                let content: String
                if requiresFullSanitization {
                    content = SecureHTMLFormatter.format(
                        footnoteDocument,
                        source: footnote.source,
                        lineBreakMode: context.markdownLineBreakMode
                    )
                } else {
                    let formattedFootnote = SecureHTMLFormatter.format(
                        footnoteDocument,
                        source: footnote.source,
                        context: context
                    )
                    content = formattedFootnote.html
                    resources.formUnion(formattedFootnote.resources)
                    warnings.append(contentsOf: formattedFootnote.warnings)
                }
                html += "<li id=\"fn-\(safeID)\" data-marklook-anchor=\"footnote-\(safeID)\">\(content)"
                if referenceCounts[footnote.id, default: 0] > 0 {
                    html += " <a class=\"footnote-backref\" href=\"#fnref-\(safeID)\" aria-label=\"Back to reference\">↩</a>"
                }
                html += "</li>"
            }
            html += "</ol></section>"
        }
        let extensionPostprocessing = postprocessingStartedAt.duration(to: clock.now)

        let htmlFragment: String
        let sanitizerTiming: HTMLSanitizerTiming
        if requiresFullSanitization {
            let sanitized = try sanitizer.sanitize(html, context: context)
            htmlFragment = sanitized.fragment
            resources = sanitized.resources
            warnings = sanitized.warnings
            sanitizerTiming = sanitized.timing
        } else {
            htmlFragment = html
            sanitizerTiming = HTMLSanitizerTiming(
                parsing: .zero,
                transforming: .zero,
                cleaning: .zero,
                serializing: .zero
            )
        }
        let markdownTitle = document.children.lazy.compactMap { ($0 as? Heading)?.plainText }.first
        return RenderOutput(
            htmlFragment: htmlFragment,
            title: markdownTitle,
            resources: resources,
            warnings: warnings,
            containsMath: !processed.math.isEmpty,
            sizeClass: context.sizeClass,
            timing: RenderPipelineTiming(
                preprocessing: preprocessing,
                markdownParsing: markdownParsing,
                markdownFormatting: markdownFormatting,
                extensionPostprocessing: extensionPostprocessing,
                htmlParsing: sanitizerTiming.parsing,
                htmlTransforming: sanitizerTiming.transforming,
                htmlCleaning: sanitizerTiming.cleaning,
                htmlSerializing: sanitizerTiming.serializing
            )
        )
    }

    private func renderHTML(_ source: String, context: RenderContext) throws -> RenderOutput {
        let sanitized = try sanitizer.sanitize(source, context: context)
        return RenderOutput(
            htmlFragment: sanitized.fragment,
            title: sanitized.title,
            resources: sanitized.resources,
            warnings: sanitized.warnings,
            containsMath: false,
            sizeClass: context.sizeClass,
            timing: RenderPipelineTiming(
                preprocessing: .zero,
                markdownParsing: .zero,
                markdownFormatting: .zero,
                extensionPostprocessing: .zero,
                htmlParsing: sanitized.timing.parsing,
                htmlTransforming: sanitized.timing.transforming,
                htmlCleaning: sanitized.timing.cleaning,
                htmlSerializing: sanitized.timing.serializing
            )
        )
    }

    private func anchorID(_ input: String) -> String {
        let readable = input.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            }
        }
        if !readable.isEmpty { return readable }
        return SHA256.hash(data: Data(input.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func collisionSafeFootnoteAnchorIDs(
        for footnotes: [MarkupPreprocessor.Footnote]
    ) -> [String: String] {
        var result: [String: String] = [:]
        var used = Set<String>()

        for footnote in footnotes where result[footnote.id] == nil {
            let base = anchorID(footnote.id)
            var candidate = base
            if used.contains(candidate) {
                let hash = SHA256.hash(data: Data(footnote.id.utf8))
                    .prefix(6)
                    .map { String(format: "%02x", $0) }
                    .joined()
                candidate = "\(base)-\(hash)"
                var ordinal = 2
                while used.contains(candidate) {
                    candidate = "\(base)-\(hash)-\(ordinal)"
                    ordinal += 1
                }
            }
            result[footnote.id] = candidate
            used.insert(candidate)
        }
        return result
    }

    private func containsMeaningfulRawHTML(in markup: Markup) -> Bool {
        if let block = markup as? HTMLBlock {
            return !SecureHTMLFormatter.containsOnlyHTMLComments(block.rawHTML)
        }
        if let inline = markup as? InlineHTML {
            return !SecureHTMLFormatter.containsOnlyHTMLComments(inline.rawHTML)
        }
        return markup.children.contains { containsMeaningfulRawHTML(in: $0) }
    }
}
