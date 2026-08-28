import Foundation
import UniformTypeIdentifiers

enum DocumentFormat: String, Sendable, Codable {
    case markdown
    case html

    init(url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            self = .markdown
        case "html", "htm":
            self = .html
        default:
            throw DocumentLoadError.unsupportedType(url.pathExtension)
        }
    }
}

enum DocumentSizeClass: String, Sendable, Codable {
    case full
    case normal
    case lightweight

    static func classify(byteCount: Int) throws -> Self {
        switch byteCount {
        case 0 ... 1_000_000:
            return .full
        case 1_000_001 ... 10_000_000:
            return .normal
        case 10_000_001 ... 100_000_000:
            return .lightweight
        default:
            throw DocumentLoadError.fileTooLarge(byteCount)
        }
    }
}

enum ResourceKind: String, Sendable, Hashable, Codable {
    case image
    case stylesheet
    case font
    case media
}

struct ResourceReference: Sendable, Hashable, Codable {
    let source: String
    let resolvedURL: URL?
    let kind: ResourceKind
}

struct RenderWarning: Sendable, Hashable, Identifiable {
    let id: String
    let message: String

    init(id: String = UUID().uuidString, message: String) {
        self.id = id
        self.message = message
    }
}

struct RenderOutput: Sendable {
    let htmlFragment: String
    let title: String?
    let resources: Set<ResourceReference>
    let warnings: [RenderWarning]
    let containsMath: Bool
    let sizeClass: DocumentSizeClass
    let timing: RenderPipelineTiming
}

/// Monotonic stage timings for parsing and serializing one source generation.
///
/// The values carry neither paths nor document content and are always collected so the opt-in
/// logger and Release benchmark observe the exact production pipeline.
struct RenderPipelineTiming: Sendable, Equatable {
    let preprocessing: Duration
    let markdownParsing: Duration
    let markdownFormatting: Duration
    let extensionPostprocessing: Duration
    let htmlParsing: Duration
    let htmlTransforming: Duration
    let htmlCleaning: Duration
    let htmlSerializing: Duration
}

struct RenderContext: Sendable {
    let documentURL: URL
    let resourceAuthority: String
    let sizeClass: DocumentSizeClass
    let markdownLineBreakMode: MarkdownLineBreakMode
    let remoteContentPolicy: RemoteContentPolicy

    init(
        documentURL: URL,
        resourceAuthority: String,
        sizeClass: DocumentSizeClass,
        markdownLineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks,
        remoteContentPolicy: RemoteContentPolicy = .init()
    ) {
        self.documentURL = documentURL
        self.resourceAuthority = resourceAuthority
        self.sizeClass = sizeClass
        self.markdownLineBreakMode = markdownLineBreakMode
        self.remoteContentPolicy = remoteContentPolicy
    }
}

enum DocumentLoadError: LocalizedError, Sendable, Equatable {
    case unsupportedType(String)
    case fileTooLarge(Int)
    case binaryInput
    case invalidTextEncoding
    case temporarilyUnavailable
    case permissionDenied
    case moved
    case renderingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(ext):
            return ext.isEmpty ? "Unsupported file type." : "Unsupported file type: .\(ext)"
        case let .fileTooLarge(bytes):
            return "The file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); files over 100 MB are not opened."
        case .binaryInput:
            return "The file appears to contain binary data."
        case .invalidTextEncoding:
            return "The text encoding could not be decoded without replacing invalid bytes."
        case .temporarilyUnavailable:
            return "The file is temporarily unavailable."
        case .permissionDenied:
            return "MarkLook does not have permission to read this file or folder."
        case .moved:
            return "The file was moved or deleted."
        case let .renderingFailed(message):
            return "Rendering failed: \(message)"
        }
    }
}

extension UTType {
    static let markLookMarkdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}
