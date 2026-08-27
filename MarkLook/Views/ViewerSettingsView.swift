import SwiftUI

struct ViewerSettingsView: View {
    @AppStorage(ViewerLayoutPreferences.contentWidthKey)
    private var configuredWidth = ViewerLayoutPreferences.defaultContentWidth

    @AppStorage(ViewerLayoutPreferences.usesFullWidthKey)
    private var usesFullWidth = false

    @AppStorage(MarkdownRenderingPreferences.lineBreakModeKey)
    private var storedMarkdownLineBreakMode = MarkdownRenderingPreferences.defaultLineBreakMode.rawValue

    var body: some View {
        Form {
            Section("Reading") {
                Toggle("Use Full Window Width", isOn: $usesFullWidth)

                LabeledContent("Content Width") {
                    HStack(spacing: 10) {
                        Slider(
                            value: contentWidthBinding,
                            in: ViewerLayoutPreferences.minimumContentWidth ... ViewerLayoutPreferences.maximumContentWidth,
                            step: 40
                        )
                        .frame(width: 230)
                        .disabled(usesFullWidth)
                        .accessibilityLabel("Content Width")
                        .accessibilityValue(widthLabel)

                        Text(widthLabel)
                            .monospacedDigit()
                            .foregroundStyle(usesFullWidth ? .secondary : .primary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }

                Text("Sets the maximum width of the rendered document. Changes apply to open documents immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Markdown") {
                Picker("Single Newlines", selection: markdownLineBreakModeBinding) {
                    Text("Continue Paragraph").tag(MarkdownLineBreakMode.gfmSoftBreaks)
                    Text("Show as Line Breaks").tag(MarkdownLineBreakMode.preserveSingleNewlines)
                }
                .pickerStyle(.radioGroup)

                Text(markdownLineBreakModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Restore Default") {
                configuredWidth = ViewerLayoutPreferences.defaultContentWidth
                usesFullWidth = false
                storedMarkdownLineBreakMode = MarkdownRenderingPreferences.defaultLineBreakMode.rawValue
            }
            .disabled(
                !usesFullWidth
                    && normalizedWidth == ViewerLayoutPreferences.defaultContentWidth
                    && storedMarkdownLineBreakMode == MarkdownRenderingPreferences.defaultLineBreakMode.rawValue
            )
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 360)
    }

    private var normalizedWidth: Double {
        ViewerLayoutPreferences.normalizedContentWidth(configuredWidth)
    }

    private var widthLabel: String {
        usesFullWidth ? "Full" : "\(Int(normalizedWidth)) px"
    }

    private var contentWidthBinding: Binding<Double> {
        Binding(
            get: { normalizedWidth },
            set: { configuredWidth = ViewerLayoutPreferences.normalizedContentWidth($0) }
        )
    }

    private var markdownLineBreakMode: MarkdownLineBreakMode {
        MarkdownRenderingPreferences.lineBreakMode(storedValue: storedMarkdownLineBreakMode)
    }

    private var markdownLineBreakModeBinding: Binding<MarkdownLineBreakMode> {
        Binding(
            get: { markdownLineBreakMode },
            set: { storedMarkdownLineBreakMode = $0.rawValue }
        )
    }

    private var markdownLineBreakModeDescription: String {
        switch markdownLineBreakMode {
        case .gfmSoftBreaks:
            "Single newlines continue the same paragraph. Use two trailing spaces or a backslash for a visible line break."
        case .preserveSingleNewlines:
            "Every single newline is shown as a line break. Other Markdown syntax is unchanged."
        }
    }
}
