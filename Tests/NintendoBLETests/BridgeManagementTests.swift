import XCTest
@testable import NintendoBLE

final class BridgeManagementTests: XCTestCase {
    func testRememberedRemoteIdentityAndSlot() throws {
        let address = Data([1, 2, 3, 4, 5, 6])
        let remote = try BridgeRememberedRemote(data: Data([4, 255]) + address + Data("White".utf8))
        XCTAssertEqual(remote.index, 4)
        XCTAssertNil(remote.slot)
        XCTAssertEqual(remote.address, address)
        XCTAssertEqual(remote.name, "White")
        XCTAssertEqual(try remote.renamed("Mario").name, "Mario")
        XCTAssertThrowsError(try BridgeRememberedRemote(data: Data([7, 0]) + address + Data("Bad".utf8)))
    }
    @MainActor func testReplyDeadlineStartsAfterTransmission() async throws {
        var transmitted: (@MainActor () -> Void)?
        var request: Data?
        let session = BridgeManagementSession(replyTimeout: 20_000_000, queueTimeout: 1_000_000_000,
            transmit: { data, completion in request = data; transmitted = completion })
        let task = Task { try await session.request(4) }
        while request == nil { await Task.yield() }
        // Longer than the reply timeout, but still waiting in the local write queue.
        try await Task.sleep(nanoseconds: 60_000_000)
        transmitted?()
        let b = Array(request!)
        session.receive(Data([1, b[1], b[2], 4, 0, 0, 1, 2, 3, 0]))
        let reply = try await task.value
        XCTAssertEqual(reply, Data([0, 1, 2, 3, 0]))
    }

    @MainActor func testCancelledQueuedCommandIsRemovedAndLateTransmissionIsIgnored() async {
        var removed: [UInt16] = []
        var transmitted: (@MainActor () -> Void)?
        let session = BridgeManagementSession(cancelQueued: { removed.append($0) },
            transmit: { _, completion in transmitted = completion })
        let task = Task { try await session.request(1, payload: Data([255])) }
        while transmitted == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(removed, [1])
        transmitted?() // Must not resurrect a cancelled deadline.
        session.disconnect()
        XCTAssertEqual(removed, [1])
    }

    @MainActor func testMissingReplyAfterTransmissionTimesOut() async {
        let session = BridgeManagementSession(replyTimeout: 1_000_000, transmit: { _, completion in completion() })
        do { _ = try await session.request(4); XCTFail("Expected reply timeout") }
        catch { XCTAssertEqual(error as? BridgeManagementError, .timedOut) }
    }

    func testRuntimePlayerOrderAndDisconnectState() throws {
        let state = try BridgePlayerState(data: Data([1, 0, 3, 2, 5]))
        XCTAssertEqual(state.order, [1, 0, 3, 2])
        XCTAssertEqual(state.disconnectedSlots, [0, 2])
        XCTAssertThrowsError(try BridgePlayerState(data: Data([0, 0, 2, 3, 0])))
        XCTAssertThrowsError(try BridgePlayerState(data: Data([0, 1, 2, 4, 0])))
        XCTAssertThrowsError(try BridgePlayerState(data: Data([0, 1, 2, 3, 16])))
        XCTAssertFalse(BridgePlayerState.validOrder([0, 1, 2]))
    }

    func testNamesAndStableRemoteIdentity() throws {
        for name in ["", "  ", "bad\nname", "bad\0name", String(repeating: "é", count: 13)] {
            XCTAssertFalse(BridgeDeviceInfo.validName(name))
        }
        XCTAssertTrue(BridgeDeviceInfo.validName("リモコン"))
        let info = try BridgeDeviceInfo(data: Data([2, 1, 2, 3, 4, 5, 6]) + Data("Blue Remote".utf8))
        XCTAssertEqual(info.target, 2)
        XCTAssertEqual(info.address, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(info.name, "Blue Remote")
        XCTAssertThrowsError(try BridgeDeviceInfo(data: Data([4, 1, 2, 3, 4, 5, 6, 65])))
    }

    @MainActor func testConfirmedReplyAndMismatchedReplies() async throws {
        var session: BridgeManagementSession!
        session = BridgeManagementSession { request in
            let b = Array(request)
            XCTAssertEqual(b[0], 1)
            XCTAssertEqual(b[3], 2)
            session.receive(Data([1, b[1] &+ 1, b[2], 2, 3])) // Wrong transaction ignored.
            session.receive(Data([1, b[1], b[2], 1, 3])) // Wrong opcode ignored.
            session.receive(Data([1, b[1], b[2], 2, 0]))
        }
        let reply = try await session.request(2)
        XCTAssertTrue(reply.isEmpty)
    }

    @MainActor func testDeviceRejectionAndDisconnect() async {
        var session: BridgeManagementSession!
        session = BridgeManagementSession { request in
            let b = Array(request)
            session.receive(Data([1, b[1], b[2], b[3], 2]))
        }
        do { _ = try await session.request(1, payload: Data([3])); XCTFail("Expected unknown remote") }
        catch { XCTAssertEqual(error as? BridgeManagementError, .rejected(2)) }
        session.disconnect()
        do { _ = try await session.request(2); XCTFail("Expected disconnect") }
        catch { XCTAssertEqual(error as? BridgeManagementError, .disconnected) }
    }

    @MainActor func testInFlightCancellationReleasesCommandSlot() async throws {
        let session = BridgeManagementSession { _ in }
        let task = Task { try await session.request(2) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = Task { try await session.request(2) }
        await Task.yield()
        session.disconnect()
        do { _ = try await next.value; XCTFail("Expected disconnect") }
        catch { XCTAssertEqual(error as? BridgeManagementError, .disconnected) }
    }
}
