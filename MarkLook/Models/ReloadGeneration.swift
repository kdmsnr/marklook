/// A monotonically increasing reload identifier within the lifetime of its owning gate.
/// Scheduler gates use a pipeline-local sequence; the presentation gate uses a WebView-wide one.
struct ReloadGeneration: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: ReloadGeneration, rhs: ReloadGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies one document reload pipeline within a long-lived document session.
///
/// A new epoch is issued when same-tab navigation replaces the scheduler. Scheduler generations
/// are intentionally local to a scheduler, so the epoch prevents a late result from the previous
/// scheduler from updating the new document's native state.
struct ReloadPipelineEpoch: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt64
}

/// A WebView application attempt. `webGeneration` never goes backwards for the lifetime of the
/// long-lived WebView, even when same-tab navigation creates a fresh `ReloadScheduler` whose local
/// generation starts at one again.
struct ReloadPresentationTicket: Hashable, Sendable {
    let pipelineEpoch: ReloadPipelineEpoch
    let webGeneration: ReloadGeneration
}

/// Main-actor-owned gate between scheduler results and the long-lived WebView.
///
/// This is a value type rather than an actor because `DocumentSession` accesses it exclusively on
/// the main actor. Keeping the policy independent of AppKit/WebKit makes the navigation races
/// deterministic to unit test without launching the app.
struct ReloadPresentationGate: Sendable {
    private var currentEpoch = ReloadPipelineEpoch(rawValue: 0)
    private var latestWebGeneration = ReloadGeneration(rawValue: 0)
    private var latestTicket: ReloadPresentationTicket?

    mutating func beginPipeline() -> ReloadPipelineEpoch {
        precondition(
            currentEpoch.rawValue < UInt64.max,
            "Reload pipeline epoch exhausted its UInt64 identifier space"
        )
        currentEpoch = ReloadPipelineEpoch(rawValue: currentEpoch.rawValue + 1)
        latestTicket = nil
        return currentEpoch
    }

    func isCurrent(_ epoch: ReloadPipelineEpoch) -> Bool {
        epoch == currentEpoch && epoch.rawValue != 0
    }

    mutating func issueTicket(
        for epoch: ReloadPipelineEpoch
    ) -> ReloadPresentationTicket? {
        guard isCurrent(epoch) else { return nil }
        precondition(
            latestWebGeneration.rawValue < UInt64.max,
            "WebView reload generation exhausted its UInt64 identifier space"
        )
        latestWebGeneration = ReloadGeneration(rawValue: latestWebGeneration.rawValue + 1)
        let ticket = ReloadPresentationTicket(
            pipelineEpoch: epoch,
            webGeneration: latestWebGeneration
        )
        latestTicket = ticket
        return ticket
    }

    func accepts(_ ticket: ReloadPresentationTicket) -> Bool {
        isCurrent(ticket.pipelineEpoch) && latestTicket == ticket
    }
}

/// Serializes generation creation and stale-result checks across file-monitor, parsing, and UI
/// tasks. Values are accepted only while their originating generation remains current.
actor ReloadGenerationGate {
    private var current = ReloadGeneration(rawValue: 0)

    @discardableResult
    func next() -> ReloadGeneration {
        precondition(
            current.rawValue < UInt64.max,
            "Reload generation exhausted its UInt64 identifier space"
        )
        current = ReloadGeneration(rawValue: current.rawValue + 1)
        return current
    }

    /// Makes all work issued up to this point stale without starting a replacement task.
    @discardableResult
    func invalidate() -> ReloadGeneration {
        next()
    }

    func isCurrent(_ generation: ReloadGeneration) -> Bool {
        generation == current && generation.rawValue != 0
    }

    func currentGeneration() -> ReloadGeneration? {
        current.rawValue == 0 ? nil : current
    }

    /// Returns a completed value only if no newer reload started while it was being produced.
    func accept<Value: Sendable>(
        _ value: consuming Value,
        from generation: ReloadGeneration
    ) -> Value? {
        guard isCurrent(generation) else { return nil }
        return value
    }
}
