import Foundation
import OSLog

/// Opt-in, local-only performance logging for reload diagnostics.
///
/// Set `MARKLOOK_RELOAD_METRICS=1` in the process environment when profiling. No document path,
/// source text, or rendered HTML is logged, and measurements are not persisted by MarkLook.
enum ReloadPerformanceLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.MarkLook",
        category: "ReloadPerformance"
    )

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MARKLOOK_RELOAD_METRICS"] == "1"
    }

    static func record<Output: Sendable>(
        snapshot: ReloadSnapshot<Output>,
        decode: Duration,
        render: Duration,
        renderStages: RenderPipelineTiming,
        webRoundTrip: Duration,
        webRuntimeMilliseconds: Double?,
        stale: Bool
    ) {
        guard isEnabled else { return }

        let timing = snapshot.timing
        logger.debug(
            "reload generation=\(snapshot.generation.rawValue, privacy: .public) bytes=\(snapshot.fingerprint.byteCount, privacy: .public) event_to_start_ms=\(timing.eventToProcessing?.markLookMilliseconds ?? -1, format: .fixed(precision: 3), privacy: .public) read_ms=\(timing.read.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) fingerprint_ms=\(timing.fingerprint.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) process_ms=\(timing.process.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) decode_ms=\(decode.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) render_ms=\(render.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) preprocess_ms=\(renderStages.preprocessing.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) markdown_parse_ms=\(renderStages.markdownParsing.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) markdown_format_ms=\(renderStages.markdownFormatting.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) extension_postprocess_ms=\(renderStages.extensionPostprocessing.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) html_parse_ms=\(renderStages.htmlParsing.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) html_transform_ms=\(renderStages.htmlTransforming.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) html_clean_ms=\(renderStages.htmlCleaning.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) html_serialize_ms=\(renderStages.htmlSerializing.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) web_round_trip_ms=\(webRoundTrip.markLookMilliseconds, format: .fixed(precision: 3), privacy: .public) web_runtime_ms=\(webRuntimeMilliseconds ?? -1, format: .fixed(precision: 3), privacy: .public) stale=\(stale, privacy: .public)"
        )
    }
}
