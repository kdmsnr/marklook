import XCTest
@testable import MarkLook

@MainActor
final class ReloadGenerationTests: XCTestCase {
    func testGateHasNoCurrentGenerationBeforeWorkBegins() async {
        let gate = ReloadGenerationGate()

        let current = await gate.currentGeneration()
        let zeroIsCurrent = await gate.isCurrent(ReloadGeneration(rawValue: 0))

        XCTAssertNil(current)
        XCTAssertFalse(zeroIsCurrent)
    }

    func testNewGenerationMakesEarlierResultStale() async {
        let gate = ReloadGenerationGate()
        let first = await gate.next()
        let second = await gate.next()
        let firstIsCurrent = await gate.isCurrent(first)
        let secondIsCurrent = await gate.isCurrent(second)
        let staleValue: String? = await gate.accept("old", from: first)
        let currentValue: String? = await gate.accept("new", from: second)

        XCTAssertLessThan(first, second)
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
        XCTAssertNil(staleValue)
        XCTAssertEqual(currentValue, "new")
    }

    func testInvalidateMakesCurrentWorkStale() async {
        let gate = ReloadGenerationGate()
        let issued = await gate.next()

        let invalidation = await gate.invalidate()
        let issuedIsCurrent = await gate.isCurrent(issued)
        let invalidationIsCurrent = await gate.isCurrent(invalidation)

        XCTAssertGreaterThan(invalidation, issued)
        XCTAssertFalse(issuedIsCurrent)
        XCTAssertTrue(invalidationIsCurrent)
    }

    func testConcurrentIssuanceProducesUniqueOrderedGenerations() async {
        let gate = ReloadGenerationGate()

        let generations = await withTaskGroup(
            of: ReloadGeneration.self,
            returning: [ReloadGeneration].self
        ) { group in
            for _ in 0..<200 {
                group.addTask {
                    await gate.next()
                }
            }

            var results: [ReloadGeneration] = []
            for await generation in group {
                results.append(generation)
            }
            return results
        }

        XCTAssertEqual(generations.count, 200)
        XCTAssertEqual(Set(generations).count, 200)
        XCTAssertEqual(generations.map(\.rawValue).min(), 1)
        XCTAssertEqual(generations.map(\.rawValue).max(), 200)

        let current = await gate.currentGeneration()
        XCTAssertEqual(current?.rawValue, 200)
    }
}
