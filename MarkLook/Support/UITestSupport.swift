import Foundation

@MainActor
enum UITestSupport {
    enum Scenario: String {
        case open
        case reload
        case scroll
    }

    private static let modeKey = "UITEST_MODE"
    private static let scenarioKey = "UITEST_SCENARIO"
    private static let fixtureIDKey = "UITEST_FIXTURE_ID"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[modeKey] == "1"
    }

    static var scenario: Scenario? {
        guard isEnabled,
              let rawValue = ProcessInfo.processInfo.environment[scenarioKey]
        else { return nil }
        return Scenario(rawValue: rawValue)
    }

    static var supportsAtomicUpdate: Bool {
        scenario == .reload || scenario == .scroll
    }

    static func prepareFixture() throws -> URL? {
        guard let scenario else { return nil }
        let directory = fixtureDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = fixtureURL(for: scenario)
        try Data(initialMarkdown(for: scenario).utf8).write(to: url, options: .atomic)
        return url
    }

    static func applyAtomicUpdate(to url: URL) throws {
        guard let scenario, supportsAtomicUpdate else { return }
        let expectedURL = fixtureURL(for: scenario).standardizedFileURL
        guard url.standardizedFileURL == expectedURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Data(updatedMarkdown(for: scenario).utf8).write(to: expectedURL, options: .atomic)
    }

    static func phaseLabel(_ phase: ViewerPhase) -> String {
        switch phase {
        case .loading: "Loading"
        case .ready: "Ready"
        case .failedInitially: "Failed"
        }
    }

    private static var fixtureDirectory: URL {
        let rawID = ProcessInfo.processInfo.environment[fixtureIDKey] ?? "default"
        let safeID = rawID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "_"
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLookUITests", isDirectory: true)
            .appendingPathComponent(String(safeID), isDirectory: true)
    }

    private static func fixtureURL(for scenario: Scenario) -> URL {
        fixtureDirectory.appendingPathComponent("\(scenario.rawValue)-fixture.md")
    }

    private static func initialMarkdown(for scenario: Scenario) -> String {
        switch scenario {
        case .open:
            """
            # UI Test Document

            Open fixture ready

            - [x] Offline viewer
            - [x] Read-only document
            """
        case .reload:
            """
            # Atomic Reload Fixture

            Reload version one

            ## Stable section

            This paragraph remains anchored while the source file is replaced atomically.
            """
        case .scroll:
            scrollMarkdown(version: "one")
        }
    }

    private static func updatedMarkdown(for scenario: Scenario) -> String {
        switch scenario {
        case .open:
            initialMarkdown(for: scenario)
        case .reload:
            """
            # Atomic Reload Fixture

            Reload version two

            ## Stable section

            This paragraph remains anchored while the source file is replaced atomically.
            """
        case .scroll:
            scrollMarkdown(version: "two")
        }
    }

    private static func scrollMarkdown(version: String) -> String {
        var lines = [
            "# Scroll Fixture",
            "",
            "Scroll fixture version \(version)",
            "",
        ]
        for index in 1 ... 48 {
            let number = String(format: "%02d", index)
            lines.append("## Section \(number)")
            lines.append("")
            lines.append("Stable paragraph \(number). The content around this anchor has a deterministic height for scroll restoration checks.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
