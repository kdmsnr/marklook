import SwiftUI

/// A stable toolbar for every viewer window, including an empty Welcome tab.
struct ViewerToolbar: ToolbarContent {
    let session: DocumentSession?
    @State private var warningsArePresented = false

    private var warnings: [RenderWarning] {
        session?.warnings ?? []
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") {
                session?.goBack()
            }
            .labelStyle(.iconOnly)
            .help("Back")
            .disabled(session?.canGoBack != true)
            .accessibilityIdentifier("viewer.back")

            Button("Forward", systemImage: "chevron.right") {
                session?.goForward()
            }
            .labelStyle(.iconOnly)
            .help("Forward")
            .disabled(session?.canGoForward != true)
            .accessibilityIdentifier("viewer.forward")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !warnings.isEmpty {
                Button("\(warnings.count) warnings", systemImage: "exclamationmark.triangle") {
                    warningsArePresented.toggle()
                }
                .labelStyle(.iconOnly)
                .help("Show Warnings")
                .accessibilityIdentifier("viewer.warnings")
                .popover(isPresented: $warningsArePresented, arrowEdge: .bottom) {
                    WarningListView(warnings: warnings)
                }
            }

            Button("Reload", systemImage: "arrow.clockwise") {
                session?.reload()
            }
            .labelStyle(.iconOnly)
            .help("Reload")
            .disabled(session == nil)
            .accessibilityIdentifier("viewer.reload")
            .onChange(of: warnings.isEmpty) { _, isEmpty in
                if isEmpty {
                    warningsArePresented = false
                }
            }
        }
    }
}

private struct WarningListView: View {
    let warnings: [RenderWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Warnings")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 390, height: min(300, CGFloat(80 + warnings.count * 46)))
        .accessibilityIdentifier("viewer.warningList")
    }
}
