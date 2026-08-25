import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeDropView: View {
    @Environment(\.openDocument) private var openDocument
    @State private var isDropTarget = false
    @State private var errorMessage: String?
    @State private var didPrepareUITestFixture = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text("Open a Markdown or HTML file")
                        .font(.title2.weight(.semibold))
                    Text("Drop a file here, or choose one from your Mac.")
                        .foregroundStyle(.secondary)
                }

                Button("Open File…", action: chooseFile)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcome.open")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .accessibilityIdentifier("welcome.error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(42)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        isDropTarget ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isDropTarget ? 3 : 1.5, dash: [8, 7])
                    )
                    .padding(24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.dropZone")
        .dropDestination(for: URL.self, action: acceptDrop, isTargeted: { isDropTarget = $0 })
        .task { prepareUITestFixtureIfNeeded() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.markLookMarkdown, .html]
        panel.prompt = "Open"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            open(url)
        }
    }

    private func acceptDrop(_ urls: [URL], _: CGPoint) -> Bool {
        guard let url = urls.first, (try? DocumentFormat(url: url)) != nil else { return false }
        open(url)
        return true
    }

    private func open(_ url: URL) {
        let snapshot = WindowTabCoordinator.snapshot()
        Task {
            do {
                try await openDocument(at: url)
                await WindowTabCoordinator.attachNextWindow(
                    after: snapshot,
                    replacingParent: true
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareUITestFixtureIfNeeded() {
        guard !didPrepareUITestFixture, UITestSupport.scenario != nil else { return }
        didPrepareUITestFixture = true
        do {
            if let url = try UITestSupport.prepareFixture() {
                open(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
