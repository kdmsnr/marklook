import SwiftUI

struct ViewerSettingsView: View {
    @AppStorage(ViewerLayoutPreferences.contentWidthKey)
    private var configuredWidth = ViewerLayoutPreferences.defaultContentWidth

    @AppStorage(ViewerLayoutPreferences.usesFullWidthKey)
    private var usesFullWidth = false

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

            Button("Restore Default") {
                configuredWidth = ViewerLayoutPreferences.defaultContentWidth
                usesFullWidth = false
            }
            .disabled(
                !usesFullWidth
                    && normalizedWidth == ViewerLayoutPreferences.defaultContentWidth
            )
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 230)
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
}
