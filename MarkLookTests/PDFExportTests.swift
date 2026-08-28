import AppKit
import Foundation
import PDFKit
import WebKit
import XCTest
@testable import MarkLook

@MainActor
final class PDFExportTests: XCTestCase {
    func testDefaultFileNameUsesSourceBaseName() {
        XCTAssertEqual(
            WebViewStore.pdfDefaultFileName(
                for: URL(fileURLWithPath: "/tmp/notes/meeting.notes.md")
            ),
            "meeting.notes"
        )
    }

    func testPDFPrintInfoUsesPaginatedSaveJob() {
        let printInfo = WebViewStore.pdfPrintInfo()

        XCTAssertEqual(printInfo.jobDisposition, .save)
        XCTAssertEqual(printInfo.horizontalPagination, .fit)
        XCTAssertEqual(printInfo.verticalPagination, .automatic)
        XCTAssertFalse(printInfo.isHorizontallyCentered)
        XCTAssertFalse(printInfo.isVerticallyCentered)
        XCTAssertEqual(printInfo.leftMargin, 36)
        XCTAssertEqual(printInfo.rightMargin, 36)
        XCTAssertEqual(printInfo.topMargin, 36)
        XCTAssertEqual(printInfo.bottomMargin, 36)
        XCTAssertEqual(
            printInfo.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool,
            false
        )
        XCTAssertNil(
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL],
            "The destination is applied only after the user approves the PDF panel."
        )
    }

    func testApprovedPDFPanelSettingsCreateAFileSaveJob() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("approved-destination.pdf")
        let pdfInfo = NSPDFInfo()
        pdfInfo.url = destinationURL
        pdfInfo.orientation = .landscape
        pdfInfo.paperSize = NSSize(width: 792, height: 612)

        let printInfo = try XCTUnwrap(WebViewStore.pdfPrintInfo(for: pdfInfo))

        XCTAssertEqual(printInfo.jobDisposition, .save)
        XCTAssertEqual(
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL,
            destinationURL
        )
        XCTAssertEqual(printInfo.orientation, .landscape)
        XCTAssertEqual(printInfo.paperSize, pdfInfo.paperSize)
        XCTAssertEqual(
            printInfo.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool,
            false
        )
    }

    func testPDFPanelSettingsRejectMissingAndDirectoryDestinations() {
        let pdfInfo = NSPDFInfo()
        XCTAssertNil(WebViewStore.pdfPrintInfo(for: pdfInfo))

        pdfInfo.url = FileManager.default.temporaryDirectory
        XCTAssertNil(WebViewStore.pdfPrintInfo(for: pdfInfo))
    }

    func testPrintStylesPreferLightPagesAndAvoidBreakingRichBlocks() throws {
        let stylesheet = try bundledTextResource(named: "Viewer.css")

        XCTAssertTrue(stylesheet.contains("@media print"))
        XCTAssertTrue(stylesheet.contains(":host { color-scheme: light; }"))
        XCTAssertTrue(stylesheet.contains("break-inside: avoid-page"))
        XCTAssertTrue(stylesheet.contains("details.callout:not([open])"))
        XCTAssertTrue(stylesheet.contains("thead { display: table-header-group; }"))
    }

    func testPDFExportDoesNotFallBackToAnApplicationModalPanelWithoutAWindow() {
        let documentURL = URL(fileURLWithPath: "/tmp/detached-document.md")
        let store = WebViewStore(
            documentURL: documentURL,
            scopes: [.file(documentURL)],
            resourceAuthority: "detached-pdf-test",
            dependencyLoaded: { _ in }
        )
        var completionCalled = false

        let started = store.exportPDF(documentURL: documentURL) {
            completionCalled = true
        }

        XCTAssertFalse(started)
        XCTAssertFalse(completionCalled)
    }

    func testRenderedMarkdownProducesReadablePDFDataWithoutUI() async throws {
        let documentURL = URL(fileURLWithPath: "/tmp/backend-pdf-fixture.md")
        let resourceAuthority = "backend-pdf-test"
        let output = try await GFMRenderEngine().render(
            source: """
            # Backend PDF Fixture

            Searchable paragraph from the rendered Markdown document.

            | Column | Value |
            | --- | ---: |
            | PDF | 42 |

            ```swift
            let format = "PDF"
            ```
            """,
            format: .markdown,
            context: RenderContext(
                documentURL: documentURL,
                resourceAuthority: resourceAuthority,
                sizeClass: .full
            )
        )
        let frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        let webView = WKWebView(frame: frame)
        let navigation = PDFNavigationWaiter()
        let stylesheet = try bundledTextResource(named: "Viewer.css")
            .replacingOccurrences(of: ":host", with: ":root")
        try await navigation.load(
            """
            <!doctype html>
            <html>
              <head>
                <meta charset="utf-8">
                <style>\(stylesheet)</style>
              </head>
              <body><article id="document-content">\(output.htmlFragment)</article></body>
            </html>
            """,
            in: webView
        )

        let configuration = WKPDFConfiguration()
        configuration.rect = webView.bounds
        let data = try await webView.pdf(configuration: configuration)
        let document = try XCTUnwrap(PDFDocument(data: data))

        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "com.adobe.pdf"
        )
        attachment.name = "backend-pdf-fixture.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Backend PDF Fixture") == true)
        XCTAssertTrue(document.string?.contains("Searchable paragraph") == true)
    }

    private func bundledTextResource(named fileName: String) throws -> String {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTFail("Missing bundled resource: \(fileName)")
        return ""
    }
}

@MainActor
private final class PDFNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finish(with: .success(()))
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error
    ) {
        finish(with: .failure(error))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, any Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
