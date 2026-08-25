import SwiftUI

struct ViewerIssueOverlay: View {
    let issue: ViewerIssue
    let retry: () -> Void
    let grantAccess: () -> Void
    let locate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 10) {
                    switch issue.kind {
                    case .permission:
                        Button("Grant Folder Access…", action: grantAccess)
                    case .moved:
                        Button("Locate…", action: locate)
                    case .reload, .encoding, .rendering:
                        Button("Retry", action: retry)
                    }

                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.issue")
    }

    private var symbolName: String {
        switch issue.kind {
        case .permission: "lock.doc"
        case .moved: "doc.badge.ellipsis"
        case .encoding: "textformat"
        case .reload, .rendering: "exclamationmark.triangle"
        }
    }
}
struct InitialDocumentFailureView: View {
    let issue: ViewerIssue?
    let retry: () -> Void
    let grantAccess: () -> Void
    let locate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(issue?.title ?? "Unable to Open File", systemImage: "doc.badge.ellipsis")
        } description: {
            Text(issue?.message ?? "The file could not be displayed.")
        } actions: {
            HStack {
                if issue?.kind == .permission {
                    Button("Grant Folder Access…", action: grantAccess)
                } else if issue?.kind == .moved {
                    Button("Locate…", action: locate)
                } else {
                    Button("Retry", action: retry)
                }
            }
        }
        .accessibilityIdentifier("viewer.initialError")
    }
}
