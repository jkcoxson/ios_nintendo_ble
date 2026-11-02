import XCTest
@testable import NintendoBLE

final class WiiRemoteSessionTests: XCTestCase {
    private func memoryReply() -> Data { Data([0x21, 0, 0, 0, 0, 0x16, 42] + Array(repeating: 0, count: 15)) }

    @MainActor func testReplyDeadlineStartsAfterTransmissionAndQueuedRepliesAreIgnored() async throws {
        var submitting: (() -> Void)?
        var completed: ((Result<Void, Error>) -> Void)?
        let remote = WiiRemoteSession(slot: 0, replyTimeout: 10_000_000, queueTimeout: 1_000_000_000,
            transmit: { _, _, start, finish in submitting = start; completed = finish })
        let operation = Task { try await remote.readMemory(address: 0x16, count: 1) }
        while submitting == nil { await Task.yield() }
        remote.receive(memoryReply()) // An old reply while this command is still queued.
        try await Task.sleep(nanoseconds: 30_000_000)
        submitting?(); completed?(.success(()))
        remote.receive(memoryReply())
        let value = try await operation.value
        XCTAssertEqual(value, Data([42]))
    }

    @MainActor func testQueueTimeoutCancelsAndDoesNotPoisonNextExchange() async throws {
        var cancelled: [UUID] = []
        let remote = WiiRemoteSession(slot: 0, queueTimeout: 1_000_000,
            cancelQueued: { cancelled.append($0) }, transmit: { _, _, _, _ in })
        do { _ = try await remote.readMemory(address: 0x16, count: 1); XCTFail("Expected queue timeout") }
        catch { XCTAssertEqual(error as? WiiRemoteError, .queueTimedOut) }
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertFalse(remote.isAwaitingLateReply)
    }

    @MainActor func testCancelledQueuedCommandIgnoresLateCompletion() async {
        var cancelled: [UUID] = []
        var submitting: (() -> Void)?
        var completed: ((Result<Void, Error>) -> Void)?
        let remote = WiiRemoteSession(slot: 0, cancelQueued: { cancelled.append($0) },
            transmit: { _, _, start, finish in submitting = start; completed = finish })
        let operation = Task { try await remote.readMemory(address: 0x16, count: 1) }
        while completed == nil { await Task.yield() }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        submitting?(); completed?(.success(()))
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertFalse(remote.isAwaitingLateReply)
    }

    @MainActor func testLateReplyCannotSatisfyANewTransaction() async {
        let remote = WiiRemoteSession(slot: 0, replyTimeout: 1_000_000,
            transmit: { _, _, start, finish in start(); finish(.success(())) })
        do { _ = try await remote.readMemory(address: 0x16, count: 1); XCTFail("Expected reply timeout") }
        catch { XCTAssertEqual(error as? WiiRemoteError, .timedOut) }
        XCTAssertTrue(remote.isAwaitingLateReply)
        do { _ = try await remote.readMemory(address: 0x16, count: 1); XCTFail("Ambiguous reuse must wait") }
        catch { XCTAssertEqual(error as? WiiRemoteError, .busy) }
        remote.receive(memoryReply())
        XCTAssertFalse(remote.isAwaitingLateReply)
    }

    @MainActor func testATTRejectionFinishesImmediatelyAndAllowsNextCommand() async {
        let remote = WiiRemoteSession(slot: 0, transmit: { _, _, start, finish in
            start(); finish(.failure(NintendoBLEError.writeQueueFull))
        })
        do { _ = try await remote.readMemory(address: 0x16, count: 1); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? NintendoBLEError, .writeQueueFull) }
        XCTAssertFalse(remote.isAwaitingLateReply)
    }
}
