import Foundation

protocol RenderEngine: Sendable {
    func render(
        source: String,
        format: DocumentFormat,
        context: RenderContext
    ) async throws -> RenderOutput
}
