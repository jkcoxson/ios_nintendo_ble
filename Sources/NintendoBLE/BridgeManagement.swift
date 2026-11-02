import Foundation

public enum BridgeManagementError: Error, Sendable, Equatable, LocalizedError {
    case unsupported, disconnected, timedOut, busy, invalidName, invalidResponse
    case rejected(UInt8)
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Update the ESP32 firmware to enable pairing and names."
        case .disconnected: return "The bridge disconnected."
        case .timedOut: return "The bridge did not confirm the command."
        case .busy: return "Another bridge command is in progress."
        case .invalidName: return "Use a nonempty name of at most 24 UTF-8 bytes, without control characters."
        case .invalidResponse: return "The bridge returned an invalid response."
        case .rejected(let code): return "The bridge rejected the command (\(code))."
        }
    }
}

/// Names are stored on the bridge. A remote's address is its stable identity, not its slot.
public struct BridgeDeviceInfo: Sendable, Equatable {
    public let target: UInt8 // 0xff = bridge, 0...3 = assigned remote slot
    public let address: Data
    public let name: String
    init(data: Data) throws {
        let b = Array(data)
        guard b.count >= 8, b[0] < 4 || b[0] == 255,
              let name = String(bytes: b.dropFirst(7), encoding: .utf8), Self.validName(name) else {
            throw BridgeManagementError.invalidResponse
        }
        target = b[0]; address = Data(b[1..<7]); self.name = name
    }
    public func renamed(_ name: String) throws -> BridgeDeviceInfo {
        guard Self.validName(name) else { throw BridgeManagementError.invalidName }
        return try BridgeDeviceInfo(data: Data([target]) + address + Data(name.utf8))
    }
    public static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 24 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// One in-flight management command per bridge. Replies confirm persistence, not just GATT delivery.
@MainActor
final class BridgeManagementSession {
    private let transmit: (Data, @escaping @MainActor () -> Void) throws -> Void
    private let cancelQueued: (UInt16) -> Void
    private let replyTimeout: UInt64
    private let queueTimeout: UInt64
    private var nextID: UInt16 = 0
    private var connected = true
    private struct Pending {
        let id: UInt16
        let opcode: UInt8
        let continuation: CheckedContinuation<Data, Error>
        var timeout: Task<Void, Never>?
    }
    private var pending: Pending?
    init(replyTimeout: UInt64 = 5_000_000_000, queueTimeout: UInt64 = 12_000_000_000,
         cancelQueued: @escaping (UInt16) -> Void = { _ in },
         transmit: @escaping (Data, @escaping @MainActor () -> Void) throws -> Void) {
        self.replyTimeout = replyTimeout; self.queueTimeout = queueTimeout
        self.cancelQueued = cancelQueued; self.transmit = transmit
    }
    convenience init(send: @escaping (Data) throws -> Void) {
        self.init(transmit: { data, completed in try send(data); completed() })
    }
    func request(_ opcode: UInt8, payload: Data = Data()) async throws -> Data {
        guard connected else { throw BridgeManagementError.disconnected }
        guard pending == nil else { throw BridgeManagementError.busy }
        try Task.checkCancellation()
        nextID &+= 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, opcode: opcode, continuation: continuation, timeout: nil)
                armTimeout(id, nanoseconds: queueTimeout)
                do {
                    try transmit(Data([1, UInt8(truncatingIfNeeded: id), UInt8(id >> 8), opcode]) + payload) { [weak self] in
                        guard let self else { return }
                        self.armTimeout(id, nanoseconds: self.replyTimeout)
                    }
                }
                catch { finish(id, .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    func receive(_ data: Data) {
        let b = Array(data)
        guard b.count >= 5, b[0] == 1, let pending,
              UInt16(b[1]) | UInt16(b[2]) << 8 == pending.id, b[3] == pending.opcode else { return }
        finish(pending.id, b[4] == 0 ? .success(Data(b.dropFirst(5))) : .failure(BridgeManagementError.rejected(b[4])))
    }
    func rejected(_ error: Error) {
        if let pending { finish(pending.id, .failure(error)) }
    }
    func disconnect() {
        connected = false
        if let pending { finish(pending.id, .failure(BridgeManagementError.disconnected)) }
    }
    private func armTimeout(_ id: UInt16, nanoseconds: UInt64) {
        guard pending?.id == id else { return }
        pending?.timeout?.cancel()
        pending?.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(id, .failure(BridgeManagementError.timedOut))
        }
    }
    private func finish(_ id: UInt16, _ result: Result<Data, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.timeout?.cancel()
        cancelQueued(id)
        current.continuation.resume(with: result)
    }
}


/// Runtime preference; slot identity and saved names never change when players move.
public struct BridgePlayerState: Sendable, Equatable {
    public let order: [UInt8]
    public let disconnectedSlots: Set<UInt8>
    init(data: Data) throws {
        let b = Array(data)
        guard b.count == 5, Self.validOrder(Array(b.prefix(4))), b[4] & 0xf0 == 0 else {
            throw BridgeManagementError.invalidResponse
        }
        order = Array(b.prefix(4))
        disconnectedSlots = Set((UInt8(0)..<4).filter { b[4] & (1 << $0) != 0 })
    }
    public static func validOrder(_ order: [UInt8]) -> Bool {
        order.count == 4 && Set(order) == Set(UInt8(0)..<4)
    }
}
