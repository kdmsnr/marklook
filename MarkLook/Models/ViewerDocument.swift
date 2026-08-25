import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ViewerDocument: FileDocument {
    static let maximumByteCount = 100_000_000

    static var readableContentTypes: [UTType] {
        [.markLookMarkdown, .html]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard data.count <= Self.maximumByteCount else {
            throw DocumentLoadError.fileTooLarge(data.count)
        }
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

extension UTType {
    static let markLookMarkdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}
