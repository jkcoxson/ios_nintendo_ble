import Foundation

public enum BridgeProtocol {
    public static let serviceUUID = "7B9C0001-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let inputUUID = "7B9C0002-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let outputUUID = "7B9C0003-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let statusUUID = "7B9C0004-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let controlUUID = "7B9C0005-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let capabilitiesUUID = "7B9C0006-9C2A-4B3D-A91F-8F4E62D4C001"
    public static let version: UInt8 = 1

    /// Fixed maximum 20-byte GATT values work even with the minimum ATT MTU.
    /// Header: slot, sequence LE16, fragment index (bit 7 = last). Payload <=16 bytes.
    public static func fragments(slot: UInt8, sequence: UInt16, report: Data) throws -> [Data] {
        guard slot < 4, !report.isEmpty, report.count <= 64 else {
            throw NintendoBLEError.invalidReport
        }
        let bytes = Array(report)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let end = min(offset + 16, bytes.count)
            let flags = UInt8(offset / 16) | (end == bytes.count ? 0x80 : 0)
            return Data([slot, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8), flags]
                + bytes[offset..<end])
        }
    }
}

public struct WiiReport: Sendable, Equatable {
    public let slot: UInt8
    public let sequence: UInt16
    /// HID report ID followed by payload; excludes the Bluetooth 0xA1 prefix.
    public let data: Data
    /// ESP32 HID-receive time, in microseconds modulo 2^32. Not a host clock.
    public var timestampMicroseconds: UInt32? = nil
}

/// Per BLE connection. Incomplete or out-of-order reports are discarded.
public struct BridgeReassembler {
    private struct Partial {
        var sequence: UInt16
        var nextIndex: UInt8
        var bytes: Data
    }
    private var partials: [UInt8: Partial] = [:]
    public init() {}

    /// Decodes an optionally negotiated batch atomically. Legacy notifications
    /// still produce zero or one report. Order and source timestamps are retained.
    public mutating func receiveReports(_ data: Data) -> [WiiReport] {
        guard data.first == 0xff else { return receive(data).map { [$0] } ?? [] }
        let bytes = Array(data)
        guard bytes.count >= 3, bytes.count <= 182, bytes[1] == 1,
              bytes[2] > 0, bytes[2] <= 32 else { return [] }
        var trial = self
        var reports: [WiiReport] = []
        var offset = 3
        for _ in 0..<bytes[2] {
            guard offset < bytes.count else { return [] }
            let length = Int(bytes[offset])
            offset += 1
            guard (9...72).contains(length), offset + length <= bytes.count,
                  bytes[offset + 3] == 0xc0,
                  let report = trial.receive(Data(bytes[offset..<(offset + length)])) else { return [] }
            reports.append(report)
            offset += length
        }
        guard offset == bytes.count else { return [] }
        self = trial
        return reports
    }

    public mutating func receive(_ data: Data) -> WiiReport? {
        let b = Array(data)
        guard b.count >= 5, b.count <= 72, b[0] < 4 else { return nil }
        if b[3] == 0xc0 {
            partials[b[0]] = nil
            guard b.count >= 9 else { return nil }
            let timestamp = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
            return WiiReport(slot: b[0], sequence: UInt16(b[1]) | UInt16(b[2]) << 8,
                             data: Data(b.dropFirst(8)), timestampMicroseconds: timestamp)
        }
        guard b.count <= 68 else { return nil }
        // Negotiated wide reports are a single complete frame. Multipart frames
        // keep the original 16-byte payload size, preventing ambiguous assembly.
        if b.count > 20 {
            partials[b[0]] = nil
            guard b[3] == 0x80 else { return nil }
            return WiiReport(slot: b[0], sequence: UInt16(b[1]) | UInt16(b[2]) << 8,
                             data: Data(b.dropFirst(4)))
        }
        let slot = b[0], index = b[3] & 0x7f
        let sequence = UInt16(b[1]) | UInt16(b[2]) << 8
        let last = b[3] & 0x80 != 0
        guard index < 4, last || b.count == 20 else {
            partials[slot] = nil
            return nil
        }
        if index == 0 {
            partials[slot] = Partial(sequence: sequence, nextIndex: 0, bytes: Data())
        }
        guard var part = partials[slot], part.sequence == sequence, part.nextIndex == index else {
            partials[slot] = nil
            return nil
        }
        part.bytes.append(contentsOf: b.dropFirst(4))
        part.nextIndex += 1
        if last {
            partials[slot] = nil
            return WiiReport(slot: slot, sequence: sequence, data: part.bytes)
        }
        partials[slot] = part
        return nil
    }
}

public struct BridgeStatus: Sendable, Equatable {
    public let pairingOpen: Bool
    public let connectedSlots: Set<UInt8>
    /// Index is the player port (0...3), value is the current remote slot. Vacant
    /// ports retain an inactive slot; filter by connectedSlots without renumbering.
    /// Nil for firmware/consumers using legacy three-byte status.
    public let playerOrder: [UInt8]?

    public init?(data: Data) {
        let b = Array(data)
        guard (b.count == 3 || b.count == 7), b[0] == BridgeProtocol.version, b[1] <= 1, b[2] & 0xf0 == 0 else {
            return nil
        }
        let order = b.count == 7 ? Array(b[3..<7]) : nil
        guard order == nil || BridgePlayerState.validOrder(order!) else { return nil }
        playerOrder = order
        pairingOpen = b[1] == 1
        connectedSlots = Set((UInt8(0)..<4).filter { b[2] & (1 << $0) != 0 })
    }
}
