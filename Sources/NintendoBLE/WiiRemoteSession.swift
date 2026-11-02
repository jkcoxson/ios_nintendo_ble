import Foundation

public enum WiiRemoteError: Error, Sendable, Equatable {
    case busy, disconnected, timedOut, queueTimedOut, invalidCalibration
    case deviceError(UInt8)
}

public struct AccelerationG: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
}

public struct WiiAccelerationCalibration: Sendable, Equatable {
    public let zero: WiiAcceleration
    public let oneG: WiiAcceleration
    public init?(data: Data) {
        let b = Array(data)
        guard b.count == 10, b.dropLast().reduce(UInt8(0x55), &+) == b[9] else { return nil }
        func sample(_ o: Int) -> WiiAcceleration {
            WiiAcceleration(x: UInt16(b[o]) << 2 | UInt16((b[o + 3] >> 4) & 3),
                            y: UInt16(b[o + 1]) << 2 | UInt16((b[o + 3] >> 2) & 3),
                            z: UInt16(b[o + 2]) << 2 | UInt16(b[o + 3] & 3))
        }
        zero = sample(0)
        oneG = sample(4)
        guard oneG.x > zero.x, oneG.y > zero.y, oneG.z > zero.z else { return nil }
    }
    public func apply(_ raw: WiiAcceleration) -> AccelerationG {
        func axis(_ v: UInt16, _ z: UInt16, _ g: UInt16) -> Double { (Double(v) - Double(z)) / (Double(g) - Double(z)) }
        return AccelerationG(x: axis(raw.x, zero.x, oneG.x), y: axis(raw.y, zero.y, oneG.y), z: axis(raw.z, zero.z, oneG.z))
    }
}

/// Optional high-level Wii commands. Obtain one from `manager.wiiRemote(slot:via:)`.
/// Do not interleave raw commands with an outstanding high-level operation: Wii ACKs
/// identify report IDs, not transaction IDs. Raw-report clients can ignore this API.
@MainActor
public final class WiiRemoteSession {
    public let slot: UInt8
    public var onInput: ((WiiInput) -> Void)?
    public private(set) var accelerationCalibration: WiiAccelerationCalibration?
    public private(set) var isConnected = true
    private let transmit: (Data, UUID, @escaping @MainActor () -> Void,
                           @escaping @MainActor (Result<Void, Error>) -> Void) throws -> Void
    private let cancelQueued: (UUID) -> Void
    private let replyTimeout: UInt64
    private let queueTimeout: UInt64
    private var rumbling = false
    private var operationInProgress = false
    private enum Reply { case ack(UInt8), memory(UInt16, Int) }
    private struct Pending {
        let id: UUID
        let reply: Reply
        let continuation: CheckedContinuation<Data, Error>
        var timeout: Task<Void, Never>?
        var submitted = false
    }
    private var pending: Pending?

    // Wii replies have no transaction IDs. After an ambiguous timeout/cancellation,
    // wait for that reply (or a remote reconnect) before issuing another exchange.
    private var orphanedReply: Reply?
    public var isAwaitingLateReply: Bool { orphanedReply != nil }

    init(slot: UInt8, replyTimeout: UInt64 = 2_000_000_000, queueTimeout: UInt64 = 12_000_000_000,
         cancelQueued: @escaping (UUID) -> Void = { _ in },
         transmit: @escaping (Data, UUID, @escaping @MainActor () -> Void,
                              @escaping @MainActor (Result<Void, Error>) -> Void) throws -> Void) {
        self.slot = slot; self.replyTimeout = replyTimeout; self.queueTimeout = queueTimeout
        self.cancelQueued = cancelQueued; self.transmit = transmit
    }
    convenience init(slot: UInt8, send: @escaping (Data) throws -> Void) {
        self.init(slot: slot, transmit: { data, _, submitting, completed in
            submitting(); try send(data); completed(.success(()))
        })
    }
    private func send(_ data: Data) throws {
        try transmit(data, UUID(), {}, { _ in })
    }

    public func setRumble(_ active: Bool) throws {
        guard isConnected else { throw WiiRemoteError.disconnected }
        guard !operationInProgress, orphanedReply == nil else { throw WiiRemoteError.busy }
        guard rumbling != active else { return }
        try send(WiiOutput.rumble(active))
        rumbling = active
    }

    public func setPlayerLEDs(mask: UInt8) throws {
        guard isConnected else { throw WiiRemoteError.disconnected }
        guard !operationInProgress, orphanedReply == nil else { throw WiiRemoteError.busy }
        try send(WiiOutput.playerLEDs(mask: mask, rumble: rumbling))
    }

    public func readMemory(address: UInt32, count: UInt16) async throws -> Data {
        try beginOperation()
        defer { operationInProgress = false }
        guard count > 0, count <= 16 else { throw NintendoBLEError.invalidReport }
        return try await exchange(WiiOutput.readMemory(address: address, count: count, rumble: rumbling),
                                  reply: .memory(UInt16(truncatingIfNeeded: address), Int(count)))
    }

    /// Reads and validates EEPROM calibration, falling back to its redundant copy.
    public func loadAccelerationCalibration() async throws -> WiiAccelerationCalibration {
        for address: UInt32 in [0x16, 0x20] {
            let data = try await readMemory(address: address, count: 10)
            if let calibration = WiiAccelerationCalibration(data: data) {
                accelerationCalibration = calibration
                return calibration
            }
        }
        throw WiiRemoteError.invalidCalibration
    }

    /// Enables IR and continuous reports. A sensor bar (or other IR reference) is required
    /// for points. Extension mode preserves the last 6 bytes for extension/MotionPlus data.
    /// This configures the camera, not an attached extension or MotionPlus.
    public func enableIR(includeExtension: Bool = false) async throws {
        try beginOperation()
        defer { operationInProgress = false }
        let r: UInt8 = rumbling ? 1 : 0
        var commands = [Data([0x13, 6 | r]), Data([0x1a, 6 | r])]
        let registers: [(UInt32, [UInt8])] = [
            (0x04b00030, [1]),
            (0x04b00000, [2, 0, 0, 0x71, 1, 0, 0xaa, 0, 0x64]),
            (0x04b0001a, [0x63, 3]),
            (0x04b00033, [includeExtension ? 1 : 3]),
            (0x04b00030, [8]),
        ]
        for (address, bytes) in registers {
            commands.append(try WiiOutput.writeMemory(address: address, bytes: Data(bytes), rumble: rumbling))
        }
        for command in commands {
            _ = try await exchange(command, reply: .ack(command.first!))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let mode = try WiiOutput.reportMode(includeExtension ? 0x37 : 0x33, rumble: rumbling, acknowledge: true)
        _ = try await exchange(mode, reply: .ack(0x12))
    }

    private func beginOperation() throws {
        guard isConnected else { throw WiiRemoteError.disconnected }
        guard !operationInProgress, orphanedReply == nil else { throw WiiRemoteError.busy }
        operationInProgress = true
    }

    private func exchange(_ data: Data, reply: Reply) async throws -> Data {
        try Task.checkCancellation()
        guard isConnected else { throw WiiRemoteError.disconnected }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, reply: reply, continuation: continuation)
                armTimeout(id: id, nanoseconds: queueTimeout, error: .queueTimedOut)
                do {
                    try transmit(data, id, { [weak self] in
                        guard self?.pending?.id == id else { return }
                        self?.pending?.submitted = true
                    }, { [weak self] result in
                        guard let self, self.pending?.id == id else { return }
                        switch result {
                        case .success:
                            self.armTimeout(id: id, nanoseconds: self.replyTimeout, error: .timedOut)
                        case .failure(let error):
                            self.finish(id: id, result: .failure(error))
                        }
                    })
                } catch { finish(id: id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError()), ambiguous: true) }
        }
    }

    private func armTimeout(id: UUID, nanoseconds: UInt64, error: WiiRemoteError) {
        guard pending?.id == id else { return }
        pending?.timeout?.cancel()
        pending?.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(id: id, result: .failure(error), ambiguous: true)
        }
    }

    private func finish(id: UUID, result: Result<Data, Error>, ambiguous: Bool = false) {
        guard let operation = pending, operation.id == id else { return }
        pending = nil
        operation.timeout?.cancel()
        if ambiguous, operation.submitted { orphanedReply = operation.reply }
        cancelQueued(id)
        operation.continuation.resume(with: result)
    }

    func receive(_ data: Data) {
        let b = Array(data)
        if let reply = orphanedReply {
            switch reply {
            case .ack(let id):
                if b.count == 5, b[0] == 0x22, b[3] == id { orphanedReply = nil }
            case .memory(let address, _):
                if b.count == 22, b[0] == 0x21, UInt16(b[4]) << 8 | UInt16(b[5]) == address { orphanedReply = nil }
            }
        } else if let operation = pending, operation.submitted {
            switch operation.reply {
            case .ack(let id):
                if b.count == 5, b[0] == 0x22, b[3] == id {
                    finish(id: operation.id, result: b[4] == 0 ? .success(Data()) : .failure(WiiRemoteError.deviceError(b[4])))
                }
            case .memory(let address, let count):
                if b.count == 22, b[0] == 0x21, UInt16(b[4]) << 8 | UInt16(b[5]) == address {
                    let error = b[3] & 15
                    if error != 0 { finish(id: operation.id, result: .failure(WiiRemoteError.deviceError(error))) }
                    else if Int(b[3] >> 4) + 1 == count {
                        finish(id: operation.id, result: .success(Data(b[6..<(6 + count)])))
                    }
                }
            }
        }
        if let input = WiiInput(report: data) { onInput?(input) }
    }

    func disconnected() {
        isConnected = false
        if let operation = pending { finish(id: operation.id, result: .failure(WiiRemoteError.disconnected)) }
    }
}
