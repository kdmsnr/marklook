import XCTest
@testable import MarkLook

final class ReloadPresentationGateTests: XCTestCase {
    func testWebGenerationsRemainMonotonicWhenSchedulerPipelineIsRecreated() throws {
        var gate = ReloadPresentationGate()
        let firstPipeline = gate.beginPipeline()
        let first = try XCTUnwrap(gate.issueTicket(for: firstPipeline))
        let second = try XCTUnwrap(gate.issueTicket(for: firstPipeline))

        let replacementPipeline = gate.beginPipeline()
        let replacement = try XCTUnwrap(gate.issueTicket(for: replacementPipeline))

        XCTAssertEqual(first.webGeneration.rawValue, 1)
        XCTAssertEqual(second.webGeneration.rawValue, 2)
        XCTAssertEqual(replacement.webGeneration.rawValue, 3)
        XCTAssertGreaterThan(replacement.webGeneration, second.webGeneration)
    }

    func testReplacingPipelineRejectsPreviouslyIssuedResult() throws {
        var gate = ReloadPresentationGate()
        let oldPipeline = gate.beginPipeline()
        let delayedOldResult = try XCTUnwrap(gate.issueTicket(for: oldPipeline))

        let newPipeline = gate.beginPipeline()

        XCTAssertFalse(gate.isCurrent(oldPipeline))
        XCTAssertFalse(gate.accepts(delayedOldResult))
        XCTAssertNil(gate.issueTicket(for: oldPipeline))
        XCTAssertTrue(gate.isCurrent(newPipeline))
    }

    func testNewerResultInSamePipelineSupersedesEarlierPresentationTicket() throws {
        var gate = ReloadPresentationGate()
        let pipeline = gate.beginPipeline()
        let earlier = try XCTUnwrap(gate.issueTicket(for: pipeline))
        let later = try XCTUnwrap(gate.issueTicket(for: pipeline))

        XCTAssertFalse(gate.accepts(earlier))
        XCTAssertTrue(gate.accepts(later))
    }
}
