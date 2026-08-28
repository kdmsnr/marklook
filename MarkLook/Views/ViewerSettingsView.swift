import SwiftUI

struct ViewerSettingsView: View {
    @AppStorage(ViewerLayoutPreferences.contentWidthKey)
    private var configuredWidth = ViewerLayoutPreferences.defaultContentWidth

    @AppStorage(ViewerLayoutPreferences.usesFullWidthKey)
    private var usesFullWidth = false

    @AppStorage(ViewerFontPreferences.fontFamilyKey)
    private var storedFontFamily = ViewerFontPreferences.defaultFontFamily.rawValue

    @AppStorage(MarkdownRenderingPreferences.lineBreakModeKey)
    private var storedMarkdownLineBreakMode = MarkdownRenderingPreferences.defaultLineBreakMode.rawValue

    @AppStorage(RemoteContentPreferences.allowedHostsKey)
    private var storedAllowedHosts = RemoteContentPreferences.defaultStoredValue

    @State private var allowedHostDraft = ""
    @State private var allowedHostValidationMessage: String?

    var body: some View {
        Form {
            Section("Reading") {
                Picker("Document Font", selection: fontFamilyBinding) {
                    ForEach(ViewerFontFamily.allCases, id: \.self) { fontFamily in
                        Text(fontFamily.displayName).tag(fontFamily)
                    }
                }

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

            Section("Remote Content") {
                Text("Allowed Domains")
                    .font(.headline)

                GroupBox {
                    if allowedHosts.isEmpty {
                        Text("No domains allowed")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(allowedHosts, id: \.self) { host in
                                    HStack {
                                        Text(host)
                                            .textSelection(.enabled)
                                        Spacer()
                                        Button {
                                            removeAllowedHost(host)
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Remove \(host)")
                                        .accessibilityLabel("Remove \(host)")
                                    }
                                    .padding(.vertical, 4)

                                    if host != allowedHosts.last {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(height: 82)
                    }
                }

                HStack {
                    TextField(
                        "Domain to allow",
                        text: $allowedHostDraft,
                        prompt: Text("e.g. assets.example.com")
                            .foregroundStyle(.tertiary)
                    )
                        .onSubmit(addAllowedHost)
                        .accessibilityLabel("Domain to allow")

                    Button("Add", action: addAllowedHost)
                        .disabled(allowedHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let allowedHostValidationMessage {
                    Text(allowedHostValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Allowing a domain lets MarkLook connect to that host for images, stylesheets, fonts, and audio or video. The host receives your IP address, request time, and full resource URL. Scripts remain blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Restore Default") {
                configuredWidth = ViewerLayoutPreferences.defaultContentWidth
                usesFullWidth = false
                storedFontFamily = ViewerFontPreferences.defaultFontFamily.rawValue
                storedMarkdownLineBreakMode = MarkdownRenderingPreferences.defaultLineBreakMode.rawValue
                storedAllowedHosts = RemoteContentPreferences.defaultStoredValue
                allowedHostDraft = ""
                allowedHostValidationMessage = nil
            }
            .disabled(
                !usesFullWidth
                    && normalizedWidth == ViewerLayoutPreferences.defaultContentWidth
                    && storedFontFamily == ViewerFontPreferences.defaultFontFamily.rawValue
                    && storedMarkdownLineBreakMode == MarkdownRenderingPreferences.defaultLineBreakMode.rawValue
                    && storedAllowedHosts == RemoteContentPreferences.defaultStoredValue
            )
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
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

    private var fontFamily: ViewerFontFamily {
        ViewerFontPreferences.fontFamily(storedValue: storedFontFamily)
    }

    private var fontFamilyBinding: Binding<ViewerFontFamily> {
        Binding(
            get: { fontFamily },
            set: { storedFontFamily = $0.rawValue }
        )
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

    private var allowedHosts: [String] {
        RemoteContentPreferences.allowedHosts(storedValue: storedAllowedHosts).sorted()
    }

    private func addAllowedHost() {
        guard let host = RemoteContentPreferences.normalizedHost(allowedHostDraft) else {
            allowedHostValidationMessage = "Enter an exact domain such as assets.example.com. URLs, wildcards, ports, local hosts, and IP addresses are not allowed."
            return
        }

        var updatedHosts = Set(allowedHosts)
        updatedHosts.insert(host)
        storedAllowedHosts = RemoteContentPreferences.storedValue(for: updatedHosts)
        allowedHostDraft = ""
        allowedHostValidationMessage = nil
    }

    private func removeAllowedHost(_ host: String) {
        var updatedHosts = Set(allowedHosts)
        updatedHosts.remove(host)
        storedAllowedHosts = RemoteContentPreferences.storedValue(for: updatedHosts)
        allowedHostValidationMessage = nil
    }
}
