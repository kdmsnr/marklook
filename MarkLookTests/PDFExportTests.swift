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

    func testPageNumberOptionControlsStandardPrintFooter() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("numbered-destination.pdf")
        let pdfInfo = NSPDFInfo()
        pdfInfo.url = destinationURL

        let withoutPageNumbers = try XCTUnwrap(
            WebViewStore.pdfPrintInfo(for: pdfInfo, includesPageNumbers: false)
        )
        let withPageNumbers = try XCTUnwrap(
            WebViewStore.pdfPrintInfo(for: pdfInfo, includesPageNumbers: true)
        )

        XCTAssertEqual(
            withoutPageNumbers.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool,
            false
        )
        XCTAssertEqual(
            withPageNumbers.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool,
            true
        )
        XCTAssertNil(withoutPageNumbers.dictionary()[ViewerWebView.suppressPageHeaderKey])
        XCTAssertEqual(
            withPageNumbers.dictionary()[ViewerWebView.suppressPageHeaderKey] as? Bool,
            true
        )
    }

    func testPDFExportAccessoryDefaultsToPageNumbersOff() {
        let controller = PDFExportAccessoryController()

        XCTAssertFalse(controller.includesPageNumbers)
        _ = controller.view
        XCTAssertGreaterThan(controller.view.frame.width, 0)
        XCTAssertGreaterThan(controller.view.frame.height, 0)
        XCTAssertEqual(
            controller.view.firstDescendant(with: PDFExportAccessoryController.pageNumbersIdentifier)?.identifier,
            PDFExportAccessoryController.pageNumbersIdentifier
        )

        controller.includesPageNumbers = true
        XCTAssertTrue(controller.includesPageNumbers)
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
            resourceAuthority: "detached-pdf-test"
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

    func testPrintOperationProducesPageNumbers() async throws {
        let webView = ViewerWebView(
            frame: NSRect(x: 0, y: 0, width: 612, height: 792)
        )
        let navigation = PDFNavigationWaiter()
        let paragraphs = (1 ... 120)
            .map { "<p>Printable paragraph \($0).</p>" }
            .joined()
        try await navigation.load(
            "<html><body><h1>Numbered Fixture</h1>\(paragraphs)</body></html>",
            in: webView
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 612, height: 792),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("numbered-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let pdfInfo = NSPDFInfo()
        pdfInfo.url = destinationURL
        let printInfo = try XCTUnwrap(
            WebViewStore.pdfPrintInfo(for: pdfInfo, includesPageNumbers: true)
        )
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = "Numbered Fixture"
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        let finished = expectation(description: "PDF print operation finished")
        let delegate = PDFPrintOperationDelegate(expectation: finished)
        operation.runModal(
            for: window,
            delegate: delegate,
            didRun: #selector(PDFPrintOperationDelegate.didFinish(_:success:contextInfo:)),
            contextInfo: nil
        )
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertTrue(delegate.success)

        let document = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertGreaterThan(document.pageCount, 1)
        for index in 0 ..< document.pageCount {
            XCTAssertTrue(
                document.page(at: index)?.string?.contains(
                    "Page \(index + 1) of \(document.pageCount)"
                ) == true
            )
        }
        XCTAssertFalse(document.page(at: 1)?.string?.contains("Numbered Fixture") == true)

        let attachment = XCTAttachment(
            data: try Data(contentsOf: destinationURL),
            uniformTypeIdentifier: "com.adobe.pdf"
        )
        attachment.name = "numbered-print.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
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
private final class PDFPrintOperationDelegate: NSObject {
    private let expectation: XCTestExpectation
    private(set) var success = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    @objc
    nonisolated func didFinish(
        _: NSPrintOperation,
        success: Bool,
        contextInfo _: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [self] in
            self.success = success
            self.expectation.fulfill()
        }
    }
}

private extension NSView {
    func firstDescendant(with identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == identifier { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(with: identifier) { return match }
        }
        return nil
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
