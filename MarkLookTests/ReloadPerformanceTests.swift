import Foundation
import XCTest
@testable import MarkLook

final class ReloadPerformanceTests: XCTestCase {
    func testCoreReloadP95Budget50KB() async throws {
        try await assertCoreReloadBudget(
            ReloadBenchmarkCase(label: "50KB", byteCount: 50_000, targetP95Milliseconds: 50)
        )
    }

    func testCoreReloadP95Budget100KB() async throws {
        try await assertCoreReloadBudget(
            ReloadBenchmarkCase(label: "100KB", byteCount: 100_000, targetP95Milliseconds: 75)
        )
    }

    func testCoreReloadP95Budget1MB() async throws {
        try await assertCoreReloadBudget(
            ReloadBenchmarkCase(label: "1MB", byteCount: 1_000_000, targetP95Milliseconds: 180)
        )
    }

    func testCoreReloadP95Budget5MB() async throws {
        try await assertCoreReloadBudget(
            ReloadBenchmarkCase(label: "5MB", byteCount: 5_000_000, targetP95Milliseconds: 750)
        )
    }

    private func assertCoreReloadBudget(_ benchmarkCase: ReloadBenchmarkCase) async throws {
        try requireReleaseBenchmarkOptIn()

        let report = try await runCoreBenchmark(
            benchmarkCase,
            warmupCount: 2,
            sampleCount: benchmarkSampleCount,
            stopAfterConclusiveMiss: !benchmarkFullRunEnabled
        )
        record(report)

        if report.isConclusiveEarlyMiss {
            XCTFail(report.conclusiveFailureDescription)
            return
        }

        // This is a necessary core-pipeline bound. Runtime opt-in metrics cover the remaining
        // WebView transfer and second-animation-frame portion of the product target.
        XCTAssertLessThanOrEqual(
            report.wallP95Milliseconds,
            benchmarkCase.targetP95Milliseconds,
            "\(benchmarkCase.label) core reload p95 was "
                + "\(formatted(report.wallP95Milliseconds)) ms; "
                + "the full reload budget is \(formatted(benchmarkCase.targetP95Milliseconds)) ms."
        )
    }

    func testTwentyAtomicSavesPerSecondEventuallyDisplaysFinalBytes() async throws {
        try requireReleaseBenchmarkOptIn()

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-reload-burst-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let initialText = "# Generation 0\n"
        try Data(initialText.utf8).write(to: fileURL)

        let scheduler = ReloadScheduler<String>(fileURL: fileURL) { input in
            let decoded = try CharacterDecoder().decode(input.data)
            return decoded.text
        }
        let recorder = ReloadBurstRecorder()
        let consumer = Task {
            for await event in scheduler.events {
                guard !Task.isCancelled else { return }
                switch event {
                case let .loaded(snapshot):
                    guard await scheduler.isCurrent(snapshot.generation),
                          await scheduler.acknowledgeApplied(snapshot.generation) else {
                        continue
                    }
                    await recorder.recordLoaded(
                        generation: snapshot.generation,
                        contents: snapshot.output,
                        timing: snapshot.timing
                    )
                case let .failed(failure):
                    await recorder.recordFailure(failure)
                case .unchanged:
                    break
                }
            }
        }
        defer { consumer.cancel() }

        let watcher = try DirectoryWatcher(fileURL: fileURL)
        try watcher.start { change in
            Task {
                await scheduler.signalChange(observedAt: change.observedAt)
            }
        }
        defer { watcher.cancel() }

        _ = await scheduler.reloadNow()
        try await waitForBenchmarkCondition("initial reload") {
            await recorder.latestContents == initialText
        }

        let saveCount = 40
        var finalText = initialText
        var finalSaveCompletedAt = ContinuousClock().now
        for generation in 1 ... saveCount {
            finalText = "# Generation \(generation)\n\nAtomic replacement payload \(generation).\n"
            try Data(finalText.utf8).write(to: fileURL, options: .atomic)
            finalSaveCompletedAt = ContinuousClock().now
            if generation < saveCount {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let expectedFinalText = finalText

        try await waitForBenchmarkCondition(
            "the last generation after a 20 saves/second burst",
            timeout: .seconds(3)
        ) {
            await recorder.latestContents == expectedFinalText
        }
        let finalAcknowledgementMilliseconds = finalSaveCompletedAt
            .duration(to: ContinuousClock().now)
            .markLookMilliseconds
        let failures = await recorder.failures
        let generations = await recorder.loadedGenerations
        let maximumEventLatency = await recorder.maximumEventLatencyMilliseconds
        let latestContents = await recorder.latestContents

        XCTAssertTrue(failures.isEmpty, "Reload failures: \(failures.map(\.message))")
        XCTAssertEqual(latestContents, expectedFinalText)
        XCTAssertEqual(generations, generations.sorted())
        XCTAssertEqual(Set(generations).count, generations.count)
        if let maximumEventLatency {
            XCTAssertLessThanOrEqual(
                maximumEventLatency,
                100,
                "Continuous saves must begin processing within 100 ms of an observed event."
            )
        } else {
            XCTFail("The atomic-save burst did not produce an event-to-processing measurement.")
        }

        let summary = [
            "atomic-burst saves=\(saveCount)",
            "loaded=\(generations.count)",
            "final-core-ack-ms=\(formatted(finalAcknowledgementMilliseconds))",
            "max-event-to-start-ms=\(maximumEventLatency.map(formatted) ?? "n/a")",
        ].joined(separator: " ")
        recordBenchmarkSummary(summary, name: "Atomic save burst")

        await scheduler.cancel()
    }

    private func requireReleaseBenchmarkOptIn() throws {
        guard ProcessInfo.processInfo.environment["MARKLOOK_RUN_BENCHMARKS"] == "1" else {
            throw XCTSkip(
                "Release reload benchmarks are opt-in; run script/run_reload_benchmarks.sh."
            )
        }

#if DEBUG
        throw XCTSkip("Reload performance assertions require a Release test build.")
#endif
    }

    private var benchmarkSampleCount: Int {
        let value = ProcessInfo.processInfo.environment["MARKLOOK_BENCHMARK_SAMPLES"]
            .flatMap(Int.init) ?? 20
        return min(max(value, 20), 100)
    }

    private var benchmarkFullRunEnabled: Bool {
        ProcessInfo.processInfo.environment["MARKLOOK_BENCHMARK_FULL_RUN"] == "1"
    }

    private func runCoreBenchmark(
        _ benchmarkCase: ReloadBenchmarkCase,
        warmupCount: Int,
        sampleCount: Int,
        stopAfterConclusiveMiss: Bool
    ) async throws -> ReloadBenchmarkReport {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-core-benchmark-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("benchmark.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let renderer = GFMRenderEngine()
        let decoder = CharacterDecoder()
        let scheduler = ReloadScheduler<ReloadBenchmarkOutput>(fileURL: fileURL) { input in
            let clock = ContinuousClock()
            let decodeStartedAt = clock.now
            let decoded = try decoder.decode(input.data)
            let decodeDuration = decodeStartedAt.duration(to: clock.now)
            let sizeClass = try DocumentSizeClass.classify(byteCount: input.data.count)
            let renderStartedAt = clock.now
            let output = try await renderer.render(
                source: decoded.text,
                format: .markdown,
                context: RenderContext(
                    documentURL: input.fileURL,
                    resourceAuthority: "reload-benchmark",
                    sizeClass: sizeClass
                )
            )
            let renderDuration = renderStartedAt.duration(to: clock.now)
            return ReloadBenchmarkOutput(
                decodeDuration: decodeDuration,
                renderDuration: renderDuration,
                renderStages: output.timing,
                renderedByteCount: output.htmlFragment.utf8.count
            )
        }
        var iterator = scheduler.events.makeAsyncIterator()

        do {
            for iteration in 0 ..< warmupCount {
                _ = try await performCoreReload(
                    byteCount: benchmarkCase.byteCount,
                    iteration: iteration,
                    fileURL: fileURL,
                    scheduler: scheduler,
                    iterator: &iterator
                )
            }

            var samples: [ReloadBenchmarkSample] = []
            samples.reserveCapacity(sampleCount)
            for sample in 0 ..< sampleCount {
                let measurement = try await performCoreReload(
                    byteCount: benchmarkCase.byteCount,
                    iteration: warmupCount + sample,
                    fileURL: fileURL,
                    scheduler: scheduler,
                    iterator: &iterator
                )
                samples.append(measurement)

                let report = ReloadBenchmarkReport(
                    benchmarkCase: benchmarkCase,
                    requestedSampleCount: sampleCount,
                    samples: samples
                )
                if stopAfterConclusiveMiss, report.isConclusiveEarlyMiss {
                    break
                }
            }

            await scheduler.cancel()
            return ReloadBenchmarkReport(
                benchmarkCase: benchmarkCase,
                requestedSampleCount: sampleCount,
                samples: samples
            )
        } catch {
            await scheduler.cancel()
            throw error
        }
    }

    private func performCoreReload(
        byteCount: Int,
        iteration: Int,
        fileURL: URL,
        scheduler: ReloadScheduler<ReloadBenchmarkOutput>,
        iterator: inout AsyncStream<ReloadSchedulerEvent<ReloadBenchmarkOutput>>.Iterator
    ) async throws -> ReloadBenchmarkSample {
        let data = makeBenchmarkMarkdown(byteCount: byteCount, iteration: iteration)
        try data.write(to: fileURL, options: .atomic)

        let clock = ContinuousClock()
        let wallStartedAt = clock.now
        guard let generation = await scheduler.reloadNow() else {
            throw ReloadBenchmarkError.schedulerCancelled
        }

        while let event = await iterator.next() {
            switch event {
            case let .loaded(snapshot) where snapshot.generation == generation:
                let wallDuration = wallStartedAt.duration(to: clock.now)
                guard await scheduler.acknowledgeApplied(generation) else {
                    throw ReloadBenchmarkError.couldNotAcknowledge(generation)
                }
                return ReloadBenchmarkSample(
                    wallMilliseconds: wallDuration.markLookMilliseconds,
                    readMilliseconds: snapshot.timing.read.markLookMilliseconds,
                    fingerprintMilliseconds: snapshot.timing.fingerprint.markLookMilliseconds,
                    decodeMilliseconds: snapshot.output.decodeDuration.markLookMilliseconds,
                    renderMilliseconds: snapshot.output.renderDuration.markLookMilliseconds,
                    preprocessingMilliseconds: snapshot.output.renderStages.preprocessing.markLookMilliseconds,
                    markdownParsingMilliseconds: snapshot.output.renderStages.markdownParsing.markLookMilliseconds,
                    markdownFormattingMilliseconds: snapshot.output.renderStages.markdownFormatting.markLookMilliseconds,
                    extensionPostprocessingMilliseconds: snapshot.output.renderStages.extensionPostprocessing.markLookMilliseconds,
                    htmlParsingMilliseconds: snapshot.output.renderStages.htmlParsing.markLookMilliseconds,
                    htmlTransformingMilliseconds: snapshot.output.renderStages.htmlTransforming.markLookMilliseconds,
                    htmlCleaningMilliseconds: snapshot.output.renderStages.htmlCleaning.markLookMilliseconds,
                    htmlSerializingMilliseconds: snapshot.output.renderStages.htmlSerializing.markLookMilliseconds,
                    processMilliseconds: snapshot.timing.process.markLookMilliseconds,
                    schedulerMilliseconds: snapshot.timing.schedulerWork.markLookMilliseconds,
                    renderedByteCount: snapshot.output.renderedByteCount
                )

            case let .failed(failure) where failure.generation == generation:
                throw ReloadBenchmarkError.reloadFailed(failure.message)

            case let .unchanged(eventGeneration, _) where eventGeneration == generation:
                throw ReloadBenchmarkError.unexpectedUnchanged(generation)

            default:
                continue
            }
        }

        throw ReloadBenchmarkError.eventStreamEnded
    }

    private func record(_ report: ReloadBenchmarkReport) {
        let summary: String
        if report.isConclusiveEarlyMiss {
            summary = [
                "core-reload size=\(report.benchmarkCase.label)",
                "outcome=conclusive-miss",
                "samples=\(report.samples.count)/\(report.requestedSampleCount)",
                "over-budget=\(report.overBudgetSampleCount)",
                "required-over-budget=\(report.requiredOverBudgetSampleCount)",
                "wall-observed-ms=\(report.wallObservedDescription)",
                "read-max-ms=\(formatted(report.readMaximumMilliseconds))",
                "fingerprint-max-ms=\(formatted(report.fingerprintMaximumMilliseconds))",
                "decode-max-ms=\(formatted(report.decodeMaximumMilliseconds))",
                "render-max-ms=\(formatted(report.renderMaximumMilliseconds))",
                "preprocess-max-ms=\(formatted(report.preprocessingMaximumMilliseconds))",
                "markdown-parse-max-ms=\(formatted(report.markdownParsingMaximumMilliseconds))",
                "markdown-format-max-ms=\(formatted(report.markdownFormattingMaximumMilliseconds))",
                "extension-postprocess-max-ms=\(formatted(report.extensionPostprocessingMaximumMilliseconds))",
                "html-parse-max-ms=\(formatted(report.htmlParsingMaximumMilliseconds))",
                "html-transform-max-ms=\(formatted(report.htmlTransformingMaximumMilliseconds))",
                "html-clean-max-ms=\(formatted(report.htmlCleaningMaximumMilliseconds))",
                "html-serialize-max-ms=\(formatted(report.htmlSerializingMaximumMilliseconds))",
                "process-max-ms=\(formatted(report.processMaximumMilliseconds))",
                "scheduler-max-ms=\(formatted(report.schedulerMaximumMilliseconds))",
                "rendered-bytes=\(report.maximumRenderedByteCount)",
                "target-ms=\(formatted(report.benchmarkCase.targetP95Milliseconds))",
            ].joined(separator: " ")
        } else {
            summary = [
                "core-reload size=\(report.benchmarkCase.label)",
                "outcome=full-run",
                "samples=\(report.samples.count)",
                "wall-p95-ms=\(formatted(report.wallP95Milliseconds))",
                "read-p95-ms=\(formatted(report.readP95Milliseconds))",
                "fingerprint-p95-ms=\(formatted(report.fingerprintP95Milliseconds))",
                "decode-p95-ms=\(formatted(report.decodeP95Milliseconds))",
                "render-p95-ms=\(formatted(report.renderP95Milliseconds))",
                "preprocess-p95-ms=\(formatted(report.preprocessingP95Milliseconds))",
                "markdown-parse-p95-ms=\(formatted(report.markdownParsingP95Milliseconds))",
                "markdown-format-p95-ms=\(formatted(report.markdownFormattingP95Milliseconds))",
                "extension-postprocess-p95-ms=\(formatted(report.extensionPostprocessingP95Milliseconds))",
                "html-parse-p95-ms=\(formatted(report.htmlParsingP95Milliseconds))",
                "html-transform-p95-ms=\(formatted(report.htmlTransformingP95Milliseconds))",
                "html-clean-p95-ms=\(formatted(report.htmlCleaningP95Milliseconds))",
                "html-serialize-p95-ms=\(formatted(report.htmlSerializingP95Milliseconds))",
                "process-p95-ms=\(formatted(report.processP95Milliseconds))",
                "scheduler-p95-ms=\(formatted(report.schedulerP95Milliseconds))",
                "rendered-bytes=\(report.maximumRenderedByteCount)",
                "target-ms=\(formatted(report.benchmarkCase.targetP95Milliseconds))",
            ].joined(separator: " ")
        }
        recordBenchmarkSummary(summary, name: "\(report.benchmarkCase.label) core reload")
    }

    private func recordBenchmarkSummary(_ summary: String, name: String) {
        Swift.print("MARKLOOK_BENCHMARK \(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}

private struct ReloadBenchmarkCase: Sendable {
    let label: String
    let byteCount: Int
    let targetP95Milliseconds: Double
}

private struct ReloadBenchmarkOutput: Sendable {
    let decodeDuration: Duration
    let renderDuration: Duration
    let renderStages: RenderPipelineTiming
    let renderedByteCount: Int
}

private struct ReloadBenchmarkSample: Sendable {
    let wallMilliseconds: Double
    let readMilliseconds: Double
    let fingerprintMilliseconds: Double
    let decodeMilliseconds: Double
    let renderMilliseconds: Double
    let preprocessingMilliseconds: Double
    let markdownParsingMilliseconds: Double
    let markdownFormattingMilliseconds: Double
    let extensionPostprocessingMilliseconds: Double
    let htmlParsingMilliseconds: Double
    let htmlTransformingMilliseconds: Double
    let htmlCleaningMilliseconds: Double
    let htmlSerializingMilliseconds: Double
    let processMilliseconds: Double
    let schedulerMilliseconds: Double
    let renderedByteCount: Int
}

private struct ReloadBenchmarkReport: Sendable {
    let benchmarkCase: ReloadBenchmarkCase
    let requestedSampleCount: Int
    let samples: [ReloadBenchmarkSample]

    var wallP95Milliseconds: Double { p95(\.wallMilliseconds) }
    var readP95Milliseconds: Double { p95(\.readMilliseconds) }
    var fingerprintP95Milliseconds: Double { p95(\.fingerprintMilliseconds) }
    var decodeP95Milliseconds: Double { p95(\.decodeMilliseconds) }
    var renderP95Milliseconds: Double { p95(\.renderMilliseconds) }
    var preprocessingP95Milliseconds: Double { p95(\.preprocessingMilliseconds) }
    var markdownParsingP95Milliseconds: Double { p95(\.markdownParsingMilliseconds) }
    var markdownFormattingP95Milliseconds: Double { p95(\.markdownFormattingMilliseconds) }
    var extensionPostprocessingP95Milliseconds: Double { p95(\.extensionPostprocessingMilliseconds) }
    var htmlParsingP95Milliseconds: Double { p95(\.htmlParsingMilliseconds) }
    var htmlTransformingP95Milliseconds: Double { p95(\.htmlTransformingMilliseconds) }
    var htmlCleaningP95Milliseconds: Double { p95(\.htmlCleaningMilliseconds) }
    var htmlSerializingP95Milliseconds: Double { p95(\.htmlSerializingMilliseconds) }
    var processP95Milliseconds: Double { p95(\.processMilliseconds) }
    var schedulerP95Milliseconds: Double { p95(\.schedulerMilliseconds) }
    var maximumRenderedByteCount: Int { samples.map(\.renderedByteCount).max() ?? 0 }
    var readMaximumMilliseconds: Double { maximum(\.readMilliseconds) }
    var fingerprintMaximumMilliseconds: Double { maximum(\.fingerprintMilliseconds) }
    var decodeMaximumMilliseconds: Double { maximum(\.decodeMilliseconds) }
    var renderMaximumMilliseconds: Double { maximum(\.renderMilliseconds) }
    var preprocessingMaximumMilliseconds: Double { maximum(\.preprocessingMilliseconds) }
    var markdownParsingMaximumMilliseconds: Double { maximum(\.markdownParsingMilliseconds) }
    var markdownFormattingMaximumMilliseconds: Double { maximum(\.markdownFormattingMilliseconds) }
    var extensionPostprocessingMaximumMilliseconds: Double { maximum(\.extensionPostprocessingMilliseconds) }
    var htmlParsingMaximumMilliseconds: Double { maximum(\.htmlParsingMilliseconds) }
    var htmlTransformingMaximumMilliseconds: Double { maximum(\.htmlTransformingMilliseconds) }
    var htmlCleaningMaximumMilliseconds: Double { maximum(\.htmlCleaningMilliseconds) }
    var htmlSerializingMaximumMilliseconds: Double { maximum(\.htmlSerializingMilliseconds) }
    var processMaximumMilliseconds: Double { maximum(\.processMilliseconds) }
    var schedulerMaximumMilliseconds: Double { maximum(\.schedulerMilliseconds) }

    var requiredOverBudgetSampleCount: Int {
        let p95Rank = Int(ceil(Double(requestedSampleCount) * 0.95))
        return requestedSampleCount - p95Rank + 1
    }

    var overBudgetSampleCount: Int {
        samples.count { $0.wallMilliseconds > benchmarkCase.targetP95Milliseconds }
    }

    var isConclusiveEarlyMiss: Bool {
        samples.count < requestedSampleCount
            && overBudgetSampleCount >= requiredOverBudgetSampleCount
    }

    var wallObservedDescription: String {
        samples.map { format($0.wallMilliseconds) }.joined(separator: ",")
    }

    var conclusiveFailureDescription: String {
        "\(benchmarkCase.label) conclusively misses its "
            + "\(format(benchmarkCase.targetP95Milliseconds)) ms core budget: "
            + "\(overBudgetSampleCount) of the first \(samples.count) measured samples exceeded "
            + "the target, and only \(requiredOverBudgetSampleCount) over-budget samples among "
            + "\(requestedSampleCount) force p95 over target. Observed wall ms "
            + "[\(wallObservedDescription)]; max stage ms: read=\(format(readMaximumMilliseconds)), "
            + "fingerprint=\(format(fingerprintMaximumMilliseconds)), "
            + "decode=\(format(decodeMaximumMilliseconds)), "
            + "render=\(format(renderMaximumMilliseconds)), "
            + "preprocess=\(format(preprocessingMaximumMilliseconds)), "
            + "markdownParse=\(format(markdownParsingMaximumMilliseconds)), "
            + "markdownFormat=\(format(markdownFormattingMaximumMilliseconds)), "
            + "extensionPostprocess=\(format(extensionPostprocessingMaximumMilliseconds)), "
            + "htmlParse=\(format(htmlParsingMaximumMilliseconds)), "
            + "htmlTransform=\(format(htmlTransformingMaximumMilliseconds)), "
            + "htmlClean=\(format(htmlCleaningMaximumMilliseconds)), "
            + "htmlSerialize=\(format(htmlSerializingMaximumMilliseconds)), "
            + "process=\(format(processMaximumMilliseconds))."
    }

    private func p95(_ keyPath: KeyPath<ReloadBenchmarkSample, Double>) -> Double {
        let values = samples.map { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return 0 }
        let index = max(0, Int(ceil(Double(values.count) * 0.95)) - 1)
        return values[index]
    }

    private func maximum(_ keyPath: KeyPath<ReloadBenchmarkSample, Double>) -> Double {
        samples.map { $0[keyPath: keyPath] }.max() ?? 0
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}

private actor ReloadBurstRecorder {
    private(set) var latestContents: String?
    private(set) var loadedGenerations: [ReloadGeneration] = []
    private(set) var failures: [ReloadFailure] = []
    private var eventLatencies: [Double] = []

    var maximumEventLatencyMilliseconds: Double? {
        eventLatencies.max()
    }

    func recordLoaded(
        generation: ReloadGeneration,
        contents: String,
        timing: ReloadTiming
    ) {
        latestContents = contents
        loadedGenerations.append(generation)
        if let latency = timing.eventToProcessing?.markLookMilliseconds {
            eventLatencies.append(latency)
        }
    }

    func recordFailure(_ failure: ReloadFailure) {
        failures.append(failure)
    }
}

private enum ReloadBenchmarkError: Error, CustomStringConvertible {
    case schedulerCancelled
    case couldNotAcknowledge(ReloadGeneration)
    case reloadFailed(String)
    case unexpectedUnchanged(ReloadGeneration)
    case eventStreamEnded
    case timeout(String)

    var description: String {
        switch self {
        case .schedulerCancelled:
            "The benchmark reload scheduler was cancelled."
        case let .couldNotAcknowledge(generation):
            "Could not acknowledge benchmark generation \(generation.rawValue)."
        case let .reloadFailed(message):
            "Benchmark reload failed: \(message)"
        case let .unexpectedUnchanged(generation):
            "Benchmark generation \(generation.rawValue) unexpectedly had unchanged bytes."
        case .eventStreamEnded:
            "The benchmark reload event stream ended before producing a result."
        case let .timeout(description):
            "Timed out waiting for \(description)."
        }
    }
}

private func makeBenchmarkMarkdown(byteCount: Int, iteration: Int) -> Data {
    let paragraph = String(
        repeating: "MarkLook keeps the current WebView alive while local Markdown changes. ",
        count: 8
    )
    let block = """
    ## Reload benchmark section

    \(paragraph)

    - [x] Preserve the current scroll anchor
    - [ ] Ignore stale generations
    - Render **GFM**, `inline code`, and https://example.invalid/link text

    | Stage | Expected behavior |
    | --- | --- |
    | Read | Off the main actor |
    | Render | No full WebView navigation |

    > Atomic replacement should leave the last successful document visible.

    ```swift
    let generation = previousGeneration + 1
    ```

    """
    let blockData = Data(block.utf8)
    let markerData = Data("\n<!-- benchmark-iteration-\(iteration) -->\n".utf8)
    precondition(byteCount >= markerData.count)

    var data = Data(capacity: byteCount)
    while data.count + blockData.count + markerData.count <= byteCount {
        data.append(blockData)
    }
    data.append(Data(repeating: 0x20, count: byteCount - data.count - markerData.count))
    data.append(markerData)
    precondition(data.count == byteCount)
    return data
}

private func waitForBenchmarkCondition(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !(await condition()) {
        guard clock.now < deadline else {
            throw ReloadBenchmarkError.timeout(description)
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}
