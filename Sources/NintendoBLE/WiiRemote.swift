import Foundation

public enum WiiOutput {
    public static func isValid(_ data: Data) -> Bool {
        guard let id = data.first else { return false }
        let length: Int
        switch id {
        case 0x10, 0x11, 0x13, 0x14, 0x15, 0x19, 0x1a: length = 2
        case 0x12: length = 3
        case 0x16, 0x18: length = 22
        case 0x17: length = 7
        default: return false
        }
        return data.count == length
    }

    public static func rumble(_ active: Bool) -> Data { Data([0x10, active ? 1 : 0]) }
    public static func requestStatus(rumble: Bool = false) -> Data { Data([0x15, rumble ? 1 : 0]) }
    public static func playerLEDs(mask: UInt8, rumble: Bool = false) -> Data {
        Data([0x11, (mask & 0x0f) << 4 | (rumble ? 1 : 0)])
    }
    public static func reportMode(_ mode: UInt8, continuous: Bool = true, rumble: Bool = false,
                                  acknowledge: Bool = false) throws -> Data {
        guard [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x3d, 0x3e, 0x3f].contains(mode) else {
            throw NintendoBLEError.invalidReport
        }
        return Data([0x12, (continuous ? 4 : 0) | (rumble ? 1 : 0) | (acknowledge ? 2 : 0), mode])
    }

    /// Addresses beginning 0x04 address registers; 0x00 addresses EEPROM.
    public static func readMemory(address: UInt32, count: UInt16, rumble: Bool = false) throws -> Data {
        guard count > 0, address >> 24 == 0 || address >> 24 == 4 else { throw NintendoBLEError.invalidReport }
        return Data([0x17, UInt8(address >> 24) | (rumble ? 1 : 0),
                     UInt8(truncatingIfNeeded: address >> 16), UInt8(truncatingIfNeeded: address >> 8),
                     UInt8(truncatingIfNeeded: address), UInt8(count >> 8), UInt8(truncatingIfNeeded: count)])
    }

    public static func writeMemory(address: UInt32, bytes: Data, rumble: Bool = false) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= 16, address >> 24 == 0 || address >> 24 == 4 else {
            throw NintendoBLEError.invalidReport
        }
        var report = Data([0x16, UInt8(address >> 24) | (rumble ? 1 : 0),
                           UInt8(truncatingIfNeeded: address >> 16), UInt8(truncatingIfNeeded: address >> 8),
                           UInt8(truncatingIfNeeded: address), UInt8(bytes.count)])
        report.append(bytes)
        report.append(contentsOf: repeatElement(UInt8(0), count: 16 - bytes.count))
        return report
    }
}

public struct WiiButtons: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let left = Self(rawValue: 0x0100)
    public static let right = Self(rawValue: 0x0200)
    public static let down = Self(rawValue: 0x0400)
    public static let up = Self(rawValue: 0x0800)
    public static let plus = Self(rawValue: 0x1000)
    public static let two = Self(rawValue: 0x0001)
    public static let one = Self(rawValue: 0x0002)
    public static let b = Self(rawValue: 0x0004)
    public static let a = Self(rawValue: 0x0008)
    public static let minus = Self(rawValue: 0x0010)
    public static let home = Self(rawValue: 0x0080)
}

/// Raw ADC counts, not physical g. Apply the remote's EEPROM calibration before motion fusion.
public struct WiiAcceleration: Sendable, Equatable {
    public let x: UInt16
    public let y: UInt16
    public let z: UInt16
}

public struct WiiIRPoint: Sendable, Equatable {
    /// Sensor pixel coordinates: x 0...1023, y 0...767. Missing points are nil in the array.
    public let x: UInt16
    public let y: UInt16
    public let size: UInt8?
}

public struct WiiInput: Sendable, Equatable {
    public let buttons: WiiButtons
    public let acceleration: WiiAcceleration?
    public let irPoints: [WiiIRPoint?]
    /// Unmodified extension data. Interpretation depends on extension identity, calibration,
    /// encryption state, and MotionPlus passthrough mode.
    public let extensionData: Data?

    /// Decode standard non-interleaved data modes. Status, memory replies, ACKs, and
    /// interleaved modes remain available through the original `WiiReport` callback.
    public init?(report: Data) {
        let b = Array(report)
        guard let mode = b.first else { return nil }
        let sizes: [UInt8: Int] = [0x30: 3, 0x31: 6, 0x32: 11, 0x33: 18,
                                   0x34: 22, 0x35: 22, 0x36: 22, 0x37: 22]
        guard let size = sizes[mode], b.count == size else { return nil }
        buttons = WiiButtons(rawValue: (UInt16(b[1]) << 8 | UInt16(b[2])) & 0x1f9f)
        if [0x31, 0x33, 0x35, 0x37].contains(mode) {
            acceleration = WiiAcceleration(x: UInt16(b[3]) << 2 | UInt16((b[1] >> 5) & 3),
                y: UInt16(b[4]) << 2 | UInt16((b[2] >> 4) & 2),
                z: UInt16(b[5]) << 2 | UInt16((b[2] >> 5) & 2))
        } else { acceleration = nil }
        var points: [WiiIRPoint?] = []
        func point(_ x: UInt16, _ y: UInt16, _ size: UInt8? = nil) -> WiiIRPoint? {
            x == 1023 && y == 1023 ? nil : WiiIRPoint(x: x, y: y, size: size)
        }
        if mode == 0x33 {
            for o in stride(from: 6, to: 18, by: 3) {
                points.append(point(UInt16(b[o]) | UInt16(b[o + 2] & 0x30) << 4,
                                    UInt16(b[o + 1]) | UInt16(b[o + 2] & 0xc0) << 2, b[o + 2] & 15))
            }
        } else if mode == 0x36 || mode == 0x37 {
            let start = mode == 0x36 ? 3 : 6
            for o in stride(from: start, to: start + 10, by: 5) {
                points.append(point(UInt16(b[o]) | UInt16(b[o + 2] & 0x30) << 4,
                                    UInt16(b[o + 1]) | UInt16(b[o + 2] & 0xc0) << 2))
                points.append(point(UInt16(b[o + 3]) | UInt16(b[o + 2] & 3) << 8,
                                    UInt16(b[o + 4]) | UInt16(b[o + 2] & 0x0c) << 6))
            }
        }
        irPoints = points
        let extensionOffsets: [UInt8: Int] = [0x32: 3, 0x34: 3, 0x35: 6, 0x36: 13, 0x37: 16]
        extensionData = extensionOffsets[mode].map { Data(b[$0...]) }
    }
}
