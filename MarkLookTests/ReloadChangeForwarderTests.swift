import Foundation
import XCTest
@testable import MarkLook

final class ReloadChangeForwarderTests: XCTestCase {
    func testSchedulerIsSignalledBeforeMainActorActivityBegins() async {
        let events = LockedReloadForwardingEvents()
        let observedAt = ContinuousClock().now

        await ReloadChangeForwarder.forward(
            observedAt: observedAt,
            signalChange: { receivedAt in
                events.append(receivedAt == observedAt ? "signal" : "wrong timestamp")
            },
            beginActivity: {
                events.append("activity")
            }
        )

        XCTAssertEqual(events.values, ["signal", "activity"])
    }
}

private final class LockedReloadForwardingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
