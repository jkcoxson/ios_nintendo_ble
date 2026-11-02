import Foundation

public enum ControllerSource: String, Sendable, Hashable, CaseIterable {
    case wiiBridge
    case nsoGameCube
}

/// Discovery is advisory. Only `NintendoControllerManager.connect(to:)` starts a connection.
public struct ControllerCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let source: ControllerSource
    public let rssi: Int
    public init(id: UUID, name: String, source: ControllerSource, rssi: Int = 0) {
        self.id = id; self.name = name; self.source = source; self.rssi = rssi
    }
}

public enum GameCubeButton: String, Sendable, Hashable, CaseIterable {
    case a, b, x, y, l, r, z, zl, start, home, capture
    case up, down, left, right
}

public struct Stick: Sendable, Equatable {
    /// Normalized axes, clamped to -1...1. Positive Y points up.
    public let x: Double
    public let y: Double
}

public struct BatteryState: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool
    public let hasExternalPower: Bool
}

public struct GameCubeState: Sendable, Equatable {
    public let buttons: Set<GameCubeButton>
    public let leftStick: Stick
    public let rightStick: Stick
    /// Normalized analog trigger travel in 0...1.
    public let leftTrigger: Double
    public let rightTrigger: Double
    public let battery: BatteryState?
    /// Complete received notification, including unparsed fields.
    public let rawReport: Data
}

public enum ControllerConnectionState: Sendable, Equatable {
    case connecting, ready, disconnected
    case failed(String)
}

public enum NintendoBLEError: Error, Sendable, Equatable {
    case bluetoothUnavailable
    case unknownCandidate
    case notReady
    case unsupportedOperation
    case invalidPlayerSlot
    case invalidReport
    case writeQueueFull
}
