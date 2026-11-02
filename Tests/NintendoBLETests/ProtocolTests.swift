import XCTest
@testable import NintendoBLE

final class ProtocolTests: XCTestCase {
    func testBatchesPreserveTimestampOrderAndRejectWholeMalformedBatch() throws {
        let a = Data([0, 1, 0, 0xc0, 0xff, 0xff, 0xff, 0xff, 0x37, 0, 8])
        let b = Data([2, 2, 0, 0xc0, 0, 0, 0, 0, 0x37, 0, 0])
        let frame = Data([0xff, 1, 2, UInt8(a.count)]) + a + Data([UInt8(b.count)]) + b
        var rx = BridgeReassembler()
        let reports = rx.receiveReports(frame)
        XCTAssertEqual(reports.map(\.slot), [0, 2])
        XCTAssertEqual(reports.map(\.timestampMicroseconds), [.max, 0])
        XCTAssertEqual(reports.map(\.data), [Data([0x37, 0, 8]), Data([0x37, 0, 0])])
        for end in 0..<frame.count { XCTAssertTrue(rx.receiveReports(Data(frame.prefix(end))).isEmpty) }
        XCTAssertTrue(rx.receiveReports(frame + Data([0])).isEmpty)
        for index in [1, 2, 3, 4, 7] {
            var bad = frame
            bad[index] = 0xff
            XCTAssertTrue(rx.receiveReports(bad).isEmpty)
        }
        XCTAssertEqual(rx.receiveReports(a).first?.slot, 0) // Existing firmware.
        let partial = try BridgeProtocol.fragments(slot: 0, sequence: 10, report: Data(repeating: 0x37, count: 22))
        XCTAssertNil(rx.receive(partial[0]))
        XCTAssertTrue(rx.receiveReports(Data(frame.dropLast())).isEmpty)
        XCTAssertNotNil(rx.receive(partial[1])) // Invalid batch cannot corrupt existing assembly.
        XCTAssertNil(rx.receive(partial[0]))
        XCTAssertEqual(rx.receiveReports(frame).count, 2)
        XCTAssertNil(rx.receive(partial[1])) // Complete batch supersedes stale partial.
    }
    func testTimestampedReportsAndFormatTransitions() throws {
        var rx = BridgeReassembler()
        for size in 1...64 {
            let data = Data(repeating: 0x37, count: size)
            let frame = Data([2, 0x34, 0x12, 0xc0, 0x78, 0x56, 0x34, 0x12]) + data
            let report = rx.receive(frame)
            XCTAssertEqual(report?.data, data)
            XCTAssertEqual(report?.timestampMicroseconds, 0x12345678)
            XCTAssertEqual(report?.sequence, 0x1234)
        }
        for timestamp: UInt32 in [0, .max] {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> ($0 * 8)) }
            XCTAssertEqual(rx.receive(Data([0, 0, 0, 0xc0] + bytes + [0x31]))?.timestampMicroseconds, timestamp)
        }
        XCTAssertNil(rx.receive(Data([0, 0, 0, 0xc0, 0, 0, 0, 0])))
        XCTAssertNil(rx.receive(Data([0, 0, 0, 0xc1]) + Data(repeating: 0, count: 26)))
        XCTAssertNil(rx.receive(Data([0, 0, 0, 0xc0]) + Data(repeating: 0, count: 69)))
        let legacy = try BridgeProtocol.fragments(slot: 0, sequence: 1, report: Data(repeating: 0x37, count: 22))
        XCTAssertNil(rx.receive(legacy[0]))
        XCTAssertNotNil(rx.receive(Data([0, 2, 0, 0xc0, 0, 0, 0, 0, 0x31])))
        XCTAssertNil(rx.receive(legacy[1]))
        XCTAssertNil(rx.receive(legacy[0]))
        let fallback = rx.receive(legacy[1])
        XCTAssertEqual(fallback?.data.count, 22)
        XCTAssertNil(fallback?.timestampMicroseconds)
    }
    func testWireFixtureAndEveryReportSize() throws {
        XCTAssertEqual(try BridgeProtocol.fragments(slot: 2, sequence: 0x1234, report: Data([0x30, 0, 8])),
                       [Data([2, 0x34, 0x12, 0x80, 0x30, 0, 8])])
        for size in 1...64 {
            let data = Data((0..<size).map(UInt8.init))
            let frames = try BridgeProtocol.fragments(slot: 3, sequence: 65535, report: data)
            var rx = BridgeReassembler()
            for frame in frames.dropLast() { XCTAssertNil(rx.receive(frame)) }
            XCTAssertEqual(rx.receive(frames.last!)?.data, data)
        }
    }

    func testLostAndMixedFragments() throws {
        let a = try BridgeProtocol.fragments(slot: 0, sequence: 1, report: Data(repeating: 1, count: 48))
        let b = try BridgeProtocol.fragments(slot: 0, sequence: 2, report: Data(repeating: 2, count: 48))
        var rx = BridgeReassembler()
        for frame in [a[0], a[2], b[0], a[1], b[2]] { XCTAssertNil(rx.receive(frame)) }
        for size in 0...128 { XCTAssertNil(rx.receive(Data(repeating: 255, count: size))) }
    }

    func testWideInputAndLegacyFallback() throws {
        var rx = BridgeReassembler()
        let report = Data(repeating: 0x37, count: 22)
        let legacy = try BridgeProtocol.fragments(slot: 1, sequence: 9, report: report)
        XCTAssertNil(rx.receive(legacy[0]))
        let wide = Data([1, 10, 0, 0x80]) + report
        XCTAssertEqual(rx.receive(wide), WiiReport(slot: 1, sequence: 10, data: report))
        XCTAssertNil(rx.receive(legacy[1])) // wide frame supersedes the partial report
        XCTAssertNil(rx.receive(Data([1, 11, 0, 0x81]) + report))
        XCTAssertNil(rx.receive(Data([1, 11, 0, 0x80]) + Data(repeating: 0, count: 65)))
        XCTAssertNil(rx.receive(legacy[0]))
        XCTAssertEqual(rx.receive(legacy[1])?.data, report)
    }

    func testNSOCounterCannotChangeLayout() {
        let decoder = NSOGameCubeDecoder()
        var data = [UInt8](repeating: 0, count: 63)
        data[1] = 9 << 2 | 3
        data[2] = 2 // A in the observed native report layout.
        data[5...10] = [0, 8, 128, 0, 8, 128] // Both sticks at 2048,2048.
        data[12] = 0x24
        data[13] = 0x24
        for counter in UInt8.min...UInt8.max {
            data[0] = counter
            let state = decoder.decode(Data(data))
            XCTAssertEqual(state?.buttons, [.a])
            XCTAssertEqual(state?.leftStick, Stick(x: 0, y: 0))
            XCTAssertEqual(state?.battery?.percentage, 100)
        }
        XCTAssertNil(decoder.decode(Data(repeating: 0, count: 63)))
        for size in 0..<63 { XCTAssertNil(decoder.decode(Data(repeating: 0, count: size))) }
    }

    func testWiiIRAndButtonsExcludeAccelerationBits() {
        var data: [UInt8] = [0x33, 0x60, 0x68, 128, 128, 128]
        data += [100, 200, 5] + Array(repeating: 255, count: 9)
        let state = WiiInput(report: Data(data))
        XCTAssertEqual(state?.buttons, .a)
        XCTAssertEqual(state?.acceleration?.x, 515)
        XCTAssertEqual(state?.acceleration?.y, 514)
        XCTAssertEqual(state?.irPoints.count, 4)
        XCTAssertEqual(state?.irPoints[0]?.x, 100)
        XCTAssertNil(state?.irPoints[1])
        XCTAssertNil(WiiInput(report: Data(data.dropLast())))
    }

    func testCommandsAndStatus() throws {
        let write = try WiiOutput.writeMemory(address: 0x04a400f0, bytes: Data([0x55]))
        XCTAssertEqual(Array(write.prefix(7)), [0x16, 4, 0xa4, 0, 0xf0, 1, 0x55])
        XCTAssertEqual(write.count, 22)
        XCTAssertTrue(WiiOutput.isValid(write))
        XCTAssertFalse(WiiOutput.isValid(Data([0x16, 0])))
        XCTAssertThrowsError(try WiiOutput.writeMemory(address: 0, bytes: Data(repeating: 0, count: 17)))
        XCTAssertEqual(BridgeStatus(data: Data([1, 1, 5]))?.connectedSlots, [0, 2])
        XCTAssertNil(BridgeStatus(data: Data([2, 1, 5])))
    }

    @MainActor func testDiscoveryIdentityMatching() {
        XCTAssertTrue(NintendoControllerManager.matchesNSOManufacturer([0x53, 5, 0, 0, 0, 0x7e, 5, 0x73, 0x20]))
        XCTAssertFalse(NintendoControllerManager.matchesNSOManufacturer([0x53, 5, 0, 0, 0, 0x7e, 5, 0x74, 0x20]))
        XCTAssertFalse(NintendoControllerManager.matchesNSOManufacturer([0x53, 5]))
    }

    @MainActor func testWiiAcknowledgedSetupAndCalibration() async throws {
        var remote: WiiRemoteSession!
        var sent: [Data] = []
        let calibration: [UInt8] = [0x82, 0x82, 0x82, 0x15, 0x9c, 0x9c, 0x9e, 0x38, 0x40, 0x3e]
        remote = WiiRemoteSession(slot: 0) { command in
            sent.append(command)
            if command.first == 0x17 {
                remote.receive(Data([0x21, 0, 0, 0x90, 0, 0x16] + calibration + Array(repeating: 0, count: 6)))
            } else { remote.receive(Data([0x22, 0, 0, command.first!, 0])) }
        }
        let decoded = try await remote.loadAccelerationCalibration()
        XCTAssertEqual(decoded.apply(decoded.oneG), AccelerationG(x: 1, y: 1, z: 1))
        try await remote.enableIR()
        XCTAssertEqual(sent.last, Data([0x12, 6, 0x33]))
        XCTAssertEqual(sent.filter { $0.first == 0x16 }.count, 5)
        var corrupt = calibration
        corrupt[0] ^= 1
        XCTAssertNil(WiiAccelerationCalibration(data: Data(corrupt)))
    }

    @MainActor func testWiiDeviceErrorAndDisconnectedSession() async {
        var remote: WiiRemoteSession!
        remote = WiiRemoteSession(slot: 0) { command in
            remote.receive(Data([0x22, 0, 0, command.first!, 7]))
        }
        do { try await remote.enableIR(); XCTFail("Expected device error") }
        catch { XCTAssertEqual(error as? WiiRemoteError, .deviceError(7)) }
        remote.disconnected()
        do { try remote.setRumble(true); XCTFail("Expected disconnected error") }
        catch { XCTAssertEqual(error as? WiiRemoteError, .disconnected) }
    }
}

final class StablePlayerStatusTests: XCTestCase {
    func testNegotiatedPlayersPreserveHolesAndLegacyStatusStillWorks() {
        let status = BridgeStatus(data: Data([1, 0, 0b0110, 2, 0, 1, 3]))!
        XCTAssertEqual(status.connectedSlots, [1, 2])
        XCTAssertEqual(status.playerOrder, [2, 0, 1, 3]) // Player 2 vacant, slot 1 stays player 3.
        XCTAssertNil(BridgeStatus(data: Data([1, 0, 6]))!.playerOrder)
        XCTAssertNil(BridgeStatus(data: Data([1, 0, 6, 2, 0, 1, 1])))
        XCTAssertNil(BridgeStatus(data: Data([1, 0, 6, 2, 0, 1, 4])))
        XCTAssertNil(BridgeStatus(data: Data([1, 0, 6, 2])))
    }
}
