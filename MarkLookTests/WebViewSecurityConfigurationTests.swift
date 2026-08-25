import Foundation
import WebKit
import XCTest
@testable import MarkLook

@MainActor
final class WebViewSecurityConfigurationTests: XCTestCase {
    func testWebViewUsesEphemeralStorageDisablesPageJavaScriptAndOwnsResourceScheme() {
        let documentURL = URL(fileURLWithPath: "/tmp/document.md")
        let store = WebViewStore(
            documentURL: documentURL,
            scopes: [.file(documentURL)],
            resourceAuthority: "web-session",
            dependencyLoaded: { _ in }
        )
        let configuration = store.webView.configuration

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNotNil(configuration.urlSchemeHandler(forURLScheme: "mark-resource"))
        XCTAssertNil(configuration.urlSchemeHandler(forURLScheme: "http"))
        XCTAssertNil(configuration.urlSchemeHandler(forURLScheme: "https"))
        XCTAssertFalse(store.webView.isInspectable)
        XCTAssertFalse(store.webView.allowsLinkPreview)

        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].isForMainFrameOnly)
    }

    func testShellContentSecurityPolicyHasNoNetworkOrDocumentCodeEscapeHatch() {
        let policy = WebViewStore.contentSecurityPolicy
        let directives = Set(
            policy.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        for required in [
            "default-src 'none'",
            "connect-src 'none'",
            "script-src 'none'",
            "worker-src 'none'",
            "child-src 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "manifest-src 'none'",
            "img-src mark-resource:",
            "font-src mark-resource:",
            "media-src mark-resource:",
            "style-src 'unsafe-inline' mark-resource:",
        ] {
            XCTAssertTrue(directives.contains(required), "Missing CSP directive: \(required)")
        }

        XCTAssertFalse(policy.contains("http:"))
        XCTAssertFalse(policy.contains("https:"))
        XCTAssertFalse(policy.contains("file:"))
        XCTAssertFalse(policy.contains("ws:"))
        XCTAssertFalse(policy.contains("wss:"))
        XCTAssertFalse(policy.contains("data:"))
    }
}
