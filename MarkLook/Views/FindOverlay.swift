import SwiftUI

struct FindOverlay: View {
    @Bindable var session: DocumentSession
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            TextField("Find", text: $session.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .focused($fieldIsFocused)
                .onSubmit { session.findNext() }
                .accessibilityIdentifier("viewer.findField")

            Button {
                session.findNext(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous Match")
            .disabled(session.findQuery.isEmpty)

            Button {
                session.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next Match")
            .disabled(session.findQuery.isEmpty)

            Button {
                session.isFindPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Find")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
        .onAppear { fieldIsFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.find")
    }
}
