import XCTest
@testable import NintendoBLE

final class OutputQueueTests: XCTestCase {
    @MainActor func testFairSlotsKeepFragmentsTogetherAndManagementHasPriority() throws {
        let queue = ReportWriteQueue<String>()
        try queue.enqueue(destination: "wii", frames: [Data([1]), Data([2])], kind: .wii(0))
        try queue.enqueue(destination: "wii", frames: [Data([5])], kind: .wii(0))
        try queue.enqueue(destination: "wii", frames: [Data([3])], kind: .wii(1))
        try queue.enqueue(destination: "wii", frames: [Data([4])], kind: .wii(2))
        try queue.enqueue(destination: "management", frames: [Data([0])], kind: .management(1))
        var values: [UInt8] = []
        while let frame = queue.next(now: 0, canSend: { _ in true }) {
            values.append(frame.value.first!)
            XCTAssertNil(queue.next(now: 0, canSend: { _ in true }))
            queue.acknowledge(destination: frame.destination, error: nil, retryable: false, now: 0)
        }
        XCTAssertEqual(values, [0, 1, 2, 3, 4, 5])
    }

    @MainActor func testResourceRejectionRestartsWholeReportWithBoundedBackoff() throws {
        let queue = ReportWriteQueue<String>()
        var completed = 0
        try queue.enqueue(destination: "wii", frames: [Data([1]), Data([2])], kind: .wii(0), completion: { _ in completed += 1 })
        for retry in 0..<4 {
            let time = Double(retry)
            XCTAssertEqual(queue.next(now: time, canSend: { _ in true })?.value, Data([1]))
            queue.acknowledge(destination: "wii", error: nil, retryable: false, now: time)
            XCTAssertEqual(queue.next(now: time, canSend: { _ in true })?.value, Data([2]))
            queue.acknowledge(destination: "wii", error: NintendoBLEError.writeQueueFull, retryable: true, now: time)
            XCTAssertNil(queue.next(now: time, canSend: { _ in true }))
        }
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(queue.count, 0)
    }

    @MainActor func testCancellationWaitsForOutstandingATTThenSkipsRemainingFragments() throws {
        let queue = ReportWriteQueue<String>()
        let id = UUID()
        try queue.enqueue(id: id, destination: "wii", frames: [Data([1]), Data([2])], kind: .wii(0),
                          completion: { _ in XCTFail("Cancelled command completed") })
        try queue.enqueue(destination: "wii", frames: [Data([3])], kind: .wii(1))
        XCTAssertNotNil(queue.next(now: 0, canSend: { _ in true }))
        queue.cancel(id)
        XCTAssertNil(queue.next(now: 0, canSend: { _ in true }))
        queue.acknowledge(destination: "wii", error: nil, retryable: false, now: 0)
        XCTAssertEqual(queue.next(now: 0, canSend: { _ in true })?.value, Data([3]))
    }

    @MainActor func testLostSlotFailsOnlyItsCommandsAndOldCompletionCannotSucceed() throws {
        let queue = ReportWriteQueue<String>()
        var failures = 0
        for value: UInt8 in [1, 2] {
            try queue.enqueue(destination: "wii", frames: [Data([value])], kind: .wii(0), completion: {
                if case .failure = $0 { failures += 1 } else { XCTFail("Disconnected output succeeded") }
            })
        }
        try queue.enqueue(destination: "wii", frames: [Data([3])], kind: .wii(1))
        XCTAssertNotNil(queue.next(now: 0, canSend: { _ in true }))
        queue.remove(kind: .wii(0), error: WiiRemoteError.disconnected)
        XCTAssertEqual(failures, 2)
        queue.acknowledge(destination: "wii", error: nil, retryable: false, now: 0)
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(queue.next(now: 0, canSend: { _ in true })?.value, Data([3]))
    }

    @MainActor func testCapacityIncludesInFlightAndBackpressureDoesNotConsume() throws {
        let queue = ReportWriteQueue<String>()
        try queue.enqueue(destination: "wii", frames: Array(repeating: Data([1]), count: 128), kind: .wii(0))
        XCTAssertNil(queue.next(now: 0, canSend: { _ in false }))
        XCTAssertEqual(queue.count, 128)
        XCTAssertNotNil(queue.next(now: 0, canSend: { _ in true }))
        XCTAssertThrowsError(try queue.enqueue(destination: "wii", frames: [Data([2])], kind: .wii(1)))
    }
}
