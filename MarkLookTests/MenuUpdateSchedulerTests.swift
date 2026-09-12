import Foundation
@testable import MarkLook
import XCTest

@MainActor
final class MenuUpdateSchedulerTests: XCTestCase {
    func testUpdatesWaitUntilTrackingModeEndsAndApplyLatestStateOnce() {
        let scheduler = MenuUpdateScheduler()
        var displayedState = "document"
        var updateCount = 0
        scheduler.schedule {
            displayedState = "temporary menu focus"
            updateCount += 1
        }

        // Exercise a separate tracking mode without creating menus or windows.
        let trackingMode = RunLoop.Mode("MenuUpdateSchedulerTests.tracking")
        let timer = Timer(timeInterval: 0.001, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: trackingMode)
        RunLoop.main.run(mode: trackingMode, before: Date(timeIntervalSinceNow: 0.05))
        timer.invalidate()

        XCTAssertEqual(displayedState, "document")
        XCTAssertEqual(updateCount, 0)

        scheduler.schedule {
            displayedState = "restored document focus"
            updateCount += 1
        }
        drainDefaultMode(until: { updateCount > 0 })

        XCTAssertEqual(displayedState, "restored document focus")
        XCTAssertEqual(updateCount, 1)
    }

    func testAnUpdateCanScheduleAnotherUpdate() {
        let scheduler = MenuUpdateScheduler()
        var updates: [Int] = []
        scheduler.schedule {
            updates.append(1)
            scheduler.schedule { updates.append(2) }
        }

        drainDefaultMode(until: { updates.count == 2 })

        XCTAssertEqual(updates, [1, 2])
    }

    func testReleasingSchedulerCancelsPendingUpdate() {
        var scheduler: MenuUpdateScheduler? = MenuUpdateScheduler()
        var didUpdate = false
        scheduler?.schedule { didUpdate = true }
        scheduler = nil

        let barrier = MenuUpdateScheduler()
        var didReachBarrier = false
        barrier.schedule { didReachBarrier = true }
        drainDefaultMode(until: { didReachBarrier })

        XCTAssertFalse(didUpdate)
    }

    private func drainDefaultMode(until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 1)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition(), "The scheduled menu update did not run")
    }
}
