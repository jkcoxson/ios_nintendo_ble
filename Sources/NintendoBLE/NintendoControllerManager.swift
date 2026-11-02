@preconcurrency import CoreBluetooth
import Foundation

/// Own on the main actor. Discovery, connection and input callbacks run on the main actor.
/// No scanning, connection, or reconnection occurs without an explicit app request.
@MainActor
public final class NintendoControllerManager: NSObject {
    public struct Options: Sendable {
        public var sources: Set<ControllerSource>
        public var connectionTimeout: TimeInterval
        public var batchInputReports: Bool
        public init(sources: Set<ControllerSource> = Set(ControllerSource.allCases),
                    connectionTimeout: TimeInterval = 30, batchInputReports: Bool = true) {
            self.sources = sources
            self.connectionTimeout = connectionTimeout.isFinite ? max(1, connectionTimeout) : 30
            self.batchInputReports = batchInputReports
        }
    }

    public var onDiagnostic: ((UUID, String) -> Void)?
    public var onDiscovered: ((ControllerCandidate) -> Void)?
    public var onConnectionChanged: ((UUID, ControllerConnectionState) -> Void)?
    public var onGameCubeInput: ((UUID, GameCubeState) -> Void)?
    public var onWiiReport: ((UUID, WiiReport) -> Void)?
    /// A rejected output affects this command/slot, not the bridge connection.
    public var onWiiOutputError: ((UUID, UInt8, Error) -> Void)?
    public var onBridgeStatus: ((UUID, BridgeStatus) -> Void)?
    public var onBluetoothStateChanged: ((CBManagerState) -> Void)?
    public private(set) var candidates: [UUID: ControllerCandidate] = [:]

    private let options: Options
    private var central: CBCentralManager?
    private var discoveryRequested = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var sessions: [UUID: Session] = [:]

    private static let nsoInput = CBUUID(string: "8261cba1-9435-420c-84d6-f0c75a2c8e4d")
    private static let nsoCommand = CBUUID(string: "af95885e-44b3-4a24-9cf0-483cc129469a")
    private static let nsoBasic = CBUUID(string: "649d4ac9-8eb7-4e6c-af44-1ea54fe5f005")
    private static let bridgeService = CBUUID(string: BridgeProtocol.serviceUUID)
    private static let bridgeInput = CBUUID(string: BridgeProtocol.inputUUID)
    private static let bridgeOutput = CBUUID(string: BridgeProtocol.outputUUID)
    private static let bridgeControl = CBUUID(string: BridgeProtocol.controlUUID)
    private static let bridgeStatus = CBUUID(string: BridgeProtocol.statusUUID)

    @MainActor private final class Session {
        let peripheral: CBPeripheral
        let candidate: ControllerCandidate
        let decoder = NSOGameCubeDecoder()
        var assembler = BridgeReassembler()
        var controlAssembler = BridgeReassembler()
        var management: BridgeManagementSession?
        var blockedOutputSlots = Set<UInt8>()
        var pendingServices = Set<CBService>()
        var pendingNotifications = Set<CBCharacteristic>()
        var characteristics: [CBUUID: CBCharacteristic] = [:]
        var input: CBCharacteristic?
        var command: CBCharacteristic?
        var status: BridgeStatus?
        var remotes: [UInt8: WiiRemoteSession] = [:]
        var capabilitiesPending = false
        var playerStatusExpected = false
        var initialized = false
        var ready = false
        var sequence: UInt16 = 0
        let writes = ReportWriteQueue<CBCharacteristic>()
        var writeRetry: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        init(_ peripheral: CBPeripheral, _ candidate: ControllerCandidate) {
            self.peripheral = peripheral
            self.candidate = candidate
        }
    }

    public init(options: Options = Options()) {
        self.options = options
        super.init()
    }

    /// Initializes Bluetooth without scanning. Useful before reconnecting saved identifiers.
    public func prepareBluetooth() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    /// Explicitly reconnect a previously selected bridge. Unknown identifiers require discovery.
    public func connectToKnownBridge(id: UUID, name: String) throws {
        guard let central, central.state == .poweredOn else { throw NintendoBLEError.bluetoothUnavailable }
        guard options.sources.contains(.wiiBridge) else { throw NintendoBLEError.unsupportedOperation }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw NintendoBLEError.unknownCandidate
        }
        peripherals[id] = peripheral
        candidates[id] = ControllerCandidate(id: id, name: name, source: .wiiBridge)
        try connect(to: id)
    }

    public func startDiscovery() {
        discoveryRequested = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        scanIfRequested()
    }

    public func stopDiscovery() {
        discoveryRequested = false
        central?.stopScan()
    }

    /// Call after the user selects a candidate. Advertisements are not proof of device identity;
    /// the required GATT characteristics and protocol are verified before reporting `.ready`.
    public func connect(to id: UUID) throws {
        guard let central, central.state == .poweredOn else { throw NintendoBLEError.bluetoothUnavailable }
        guard let candidate = candidates[id], let peripheral = peripherals[id] else {
            throw NintendoBLEError.unknownCandidate
        }
        guard sessions[id] == nil else { return }
        guard peripheral.state == .disconnected else { throw NintendoBLEError.notReady }
        let session = Session(peripheral, candidate)
        sessions[id] = session
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
        session.timeout = Task { [weak self, weak session] in
            guard let self, let session else { return }
            try? await Task.sleep(nanoseconds: UInt64(min(self.options.connectionTimeout, 86_400) * 1_000_000_000))
            guard !Task.isCancelled, self.sessions[id] === session, !session.ready else { return }
            self.fail(session, "Connection or controller initialization timed out (notifications pending: \(session.pendingNotifications.count), initialized: \(session.initialized))")
        }
        onConnectionChanged?(id, .connecting)
    }

    public func disconnect(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.writeRetry?.cancel()
        session.writes.disconnect()
        session.timeout?.cancel()
        session.management?.disconnect()
        for remote in session.remotes.values { remote.disconnected() }
        session.peripheral.delegate = nil
        central?.cancelPeripheralConnection(session.peripheral)
        onConnectionChanged?(id, .disconnected)
        scanIfRequested()
    }

    public func stop() {
        stopDiscovery()
        for id in Array(sessions.keys) { disconnect(id) }
        candidates.removeAll()
        peripherals.removeAll()
    }

    /// Slot is 0...3. Wii slots refer to the bridge's connected-slot bitmap.
    public func setPlayerLED(_ slot: UInt8, for id: UUID) throws {
        guard slot < 4 else { throw NintendoBLEError.invalidPlayerSlot }
        let s = try readySession(id, source: .nsoGameCube)
        try enqueue([Data([0x09, 0x91, 1, 7, 0, 8, 0, 0, 1 << slot, 0, 0, 0, 0, 0, 0, 0])],
                    to: s.command!, session: s)
    }

    public func setRumble(_ active: Bool, for id: UUID) throws {
        let s = try readySession(id, source: .nsoGameCube)
        try enqueue([Data([0x0a, 0x91, 1, 2, 0, 4, 0, 0, active ? 1 : 0, 0, 0, 0])],
                    to: s.command!, session: s)
    }

    /// Send a complete Wii HID output report (ID + payload, without 0xA2).
    /// This includes memory/register operations, IR setup, MotionPlus, extensions and speaker data.
    /// A successful return means queued locally; Wii acknowledgements arrive through `onWiiReport`.
    public func sendWiiReport(_ data: Data, slot: UInt8, via id: UUID,
                              completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) throws {
        try queueWiiReport(data, slot: slot, via: id, completion: completion)
    }

    private func queueWiiReport(_ data: Data, slot: UInt8, via id: UUID, requestID: UUID = UUID(),
                                submitting: @escaping @MainActor () -> Void = {},
                                completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) throws {
        let s = try readySession(id, source: .wiiBridge)
        guard s.status?.connectedSlots.contains(slot) == true, !s.blockedOutputSlots.contains(slot) else { throw NintendoBLEError.notReady }
        guard WiiOutput.isValid(data) else { throw NintendoBLEError.invalidReport }
        let frames = try BridgeProtocol.fragments(slot: slot, sequence: s.sequence, report: data)
        try enqueue(frames, to: s.command!, session: s, id: requestID, kind: .wii(slot),
                    submitting: submitting, result: { [weak self] result in
            if case .failure(let error) = result { self?.onWiiOutputError?(id, slot, error) }
            completion?(result)
        })
        s.sequence &+= 1
    }

    public func supportsBridgeManagement(_ id: UUID) -> Bool {
        sessions[id]?.ready == true && sessions[id]?.management != nil
    }

    public func bridgeInfo(via id: UUID) async throws -> BridgeDeviceInfo {
        try await deviceInfo(target: 255, via: id)
    }
    /// Includes assigned remotes that are currently asleep.
    public func remoteInfo(slot: UInt8, via id: UUID) async throws -> BridgeDeviceInfo {
        guard slot < 4 else { throw NintendoBLEError.invalidPlayerSlot }
        return try await deviceInfo(target: slot, via: id)
    }
    private func deviceInfo(target: UInt8, via id: UUID) async throws -> BridgeDeviceInfo {
        let data = try await management(id).request(1, payload: Data([target]))
        let info = try BridgeDeviceInfo(data: data)
        guard info.target == target else { throw BridgeManagementError.invalidResponse }
        return info
    }
    /// Reopens new Wii pairing for 30 seconds, without restarting the ESP32 or BLE link.
    public func openPairingWindow(via id: UUID) async throws {
        _ = try await management(id).request(2)
    }
    public func renameBridge(_ name: String, via id: UUID) async throws {
        try await rename(target: 255, address: Data(repeating: 0, count: 6), name: name, via: id)
    }
    public func renameRemote(_ remote: BridgeDeviceInfo, name: String, via id: UUID) async throws {
        guard remote.target < 4 else { throw NintendoBLEError.invalidPlayerSlot }
        try await rename(target: remote.target, address: remote.address, name: name, via: id)
    }
    private func rename(target: UInt8, address: Data, name: String, via id: UUID) async throws {
        guard BridgeDeviceInfo.validName(name) else { throw BridgeManagementError.invalidName }
        _ = try await management(id).request(3, payload: Data([target]) + address + Data(name.utf8))
    }
    public func supportsRemoteControl(_ id: UUID) -> Bool {
        sessions[id]?.ready == true && sessions[id]?.characteristics[CBUUID(string: BridgeProtocol.capabilitiesUUID)] != nil
    }
    public func playerState(via id: UUID) async throws -> BridgePlayerState {
        guard supportsRemoteControl(id) else { throw BridgeManagementError.unsupported }
        return try BridgePlayerState(data: await management(id).request(4))
    }
    /// A permutation of stable slots 0...3 indexed by player port. Vacant ports
    /// stay vacant until a new connection fills them. Runtime state resets on reboot.
    public func setPlayerOrder(_ order: [UInt8], via id: UUID) async throws -> BridgePlayerState {
        guard supportsRemoteControl(id) else { throw BridgeManagementError.unsupported }
        guard BridgePlayerState.validOrder(order) else { throw NintendoBLEError.invalidReport }
        return try BridgePlayerState(data: await management(id).request(5, payload: Data(order)))
    }
    /// Disconnects one remote and pauses its reconnect attempts until connectRemote or bridge reboot.
    public func disconnectRemote(_ remote: BridgeDeviceInfo, via id: UUID) async throws {
        guard supportsRemoteControl(id), remote.target < 4 else { throw BridgeManagementError.unsupported }
        let s = try readySession(id, source: .wiiBridge)
        s.blockedOutputSlots.insert(remote.target)
        s.writes.remove(kind: .wii(remote.target), error: WiiRemoteError.disconnected)
        do {
            _ = try await management(id).request(6, payload: Data([remote.target]) + remote.address)
        } catch {
            s.blockedOutputSlots.remove(remote.target)
            throw error
        }
    }
    /// Resumes reconnect attempts for a remembered remote; wake it with A if it is asleep.
    public func connectRemote(_ remote: BridgeDeviceInfo, via id: UUID) async throws {
        guard supportsRemoteControl(id), remote.target < 4 else { throw BridgeManagementError.unsupported }
        _ = try await management(id).request(7, payload: Data([remote.target]) + remote.address)
        sessions[id]?.blockedOutputSlots.remove(remote.target)
    }

    private func management(_ id: UUID) throws -> BridgeManagementSession {
        let session = try readySession(id, source: .wiiBridge)
        guard let control = session.management else { throw BridgeManagementError.unsupported }
        return control
    }

    public func wiiRemote(slot: UInt8, via id: UUID) throws -> WiiRemoteSession {
        let s = try readySession(id, source: .wiiBridge)
        guard s.status?.connectedSlots.contains(slot) == true, !s.blockedOutputSlots.contains(slot) else { throw NintendoBLEError.notReady }
        if let remote = s.remotes[slot] { return remote }
        let remote = WiiRemoteSession(slot: slot, cancelQueued: { [weak s] requestID in
            s?.writes.cancel(requestID)
        }, transmit: { [weak self, weak s] data, requestID, submitting, completed in
            guard let self, let s, self.sessions[id] === s else { throw WiiRemoteError.disconnected }
            try self.queueWiiReport(data, slot: slot, via: id, requestID: requestID,
                                    submitting: submitting, completion: completed)
        })
        s.remotes[slot] = remote
        return remote
    }

    private func readySession(_ id: UUID, source: ControllerSource) throws -> Session {
        guard let s = sessions[id], s.ready, s.command != nil else { throw NintendoBLEError.notReady }
        guard s.candidate.source == source else { throw NintendoBLEError.unsupportedOperation }
        return s
    }

    private func scanIfRequested() {
        guard discoveryRequested, let central, central.state == .poweredOn else { return }
        // NSO advertises manufacturer data rather than a dependable service UUID.
        let services = options.sources == [.wiiBridge] ? [Self.bridgeService] : nil
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func fail(_ s: Session, _ message: String) {
        let id = s.peripheral.identifier
        guard sessions.removeValue(forKey: id) != nil else { return }
        s.writeRetry?.cancel()
        s.writes.disconnect()
        s.timeout?.cancel()
        s.management?.disconnect()
        for remote in s.remotes.values { remote.disconnected() }
        s.peripheral.delegate = nil
        central?.cancelPeripheralConnection(s.peripheral)
        onDiagnostic?(id, message)
        onConnectionChanged?(id, .failed(message))
        scanIfRequested()
    }

    private func markReady(_ s: Session) {
        guard !s.ready, !s.capabilitiesPending, !s.playerStatusExpected || s.status?.playerOrder != nil else { return }
        s.ready = true
        s.timeout?.cancel()
        s.timeout = nil
        scanIfRequested()
        onDiagnostic?(s.peripheral.identifier, "Bridge/controller ready")
        onConnectionChanged?(s.peripheral.identifier, .ready)
    }

    private func enqueue(_ values: [Data], to c: CBCharacteristic, session s: Session,
                         id: UUID = UUID(), kind: ReportWriteQueue<CBCharacteristic>.Kind = .setup,
                         submitting: @escaping @MainActor () -> Void = {},
                         result: (@MainActor (Result<Void, Error>) -> Void)? = nil,
                         completed: (@MainActor () -> Void)? = nil) throws {
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        guard c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse),
              values.allSatisfy({ $0.count <= s.peripheral.maximumWriteValueLength(for: type) }) else {
            throw NintendoBLEError.invalidReport
        }
        try s.writes.enqueue(id: id, destination: c, frames: values, kind: kind, submitting: submitting) { [weak self, weak s] outcome in
            result?(outcome)
            switch outcome {
            case .success: completed?()
            case .failure(let error):
                if kind == .setup, let s { self?.fail(s, error.localizedDescription) }
            }
        }
        drain(s)
    }

    private func drain(_ s: Session) {
        guard sessions[s.peripheral.identifier] === s else { return }
        s.writeRetry?.cancel()
        s.writeRetry = nil
        while let frame = s.writes.next(now: ProcessInfo.processInfo.systemUptime, canSend: {
            $0.properties.contains(.write) || s.peripheral.canSendWriteWithoutResponse
        }) {
            let type: CBCharacteristicWriteType = frame.destination.properties.contains(.write) ? .withResponse : .withoutResponse
            s.peripheral.writeValue(frame.value, for: frame.destination, type: type)
            if type == .withResponse { return }
            s.writes.acknowledge(destination: frame.destination, error: nil, retryable: false,
                                 now: ProcessInfo.processInfo.systemUptime)
        }
        let delay = s.writes.retryAt - ProcessInfo.processInfo.systemUptime
        if delay > 0 {
            s.writeRetry = Task { [weak self, weak s] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let s else { return }
                self?.drain(s)
            }
        }
    }

    private func initializeIfReady(_ s: Session) {
        guard s.pendingServices.isEmpty, s.pendingNotifications.isEmpty, !s.initialized,
              let input = s.input, input.isNotifying, let command = s.command else { return }
        s.initialized = true
        if s.candidate.source == .wiiBridge {
            guard let status = s.characteristics[Self.bridgeStatus] else {
                fail(s, "Bridge status characteristic is missing"); return
            }
            if let capabilities = s.characteristics[CBUUID(string: BridgeProtocol.capabilitiesUUID)],
               capabilities.properties.contains(.write) {
                s.capabilitiesPending = true
                do {
                    try enqueue([Data([1])], to: capabilities, session: s)
                    onDiagnostic?(s.peripheral.identifier, "Wide input frames requested")
                    s.peripheral.readValue(for: capabilities)
                } catch { fail(s, "Bridge input negotiation failed: \(error)"); return }
            }
            s.peripheral.readValue(for: status)
            if s.status != nil { markReady(s) }
        } else {
            do {
                try enqueue([
                    Data([2, 0x91, 1, 4, 0, 8, 0, 0, 0x40, 0x7e, 0, 0, 0, 0x30, 1, 0]),
                    Data([3, 0x91, 0, 0x0d, 0, 8, 0, 0, 1, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
                    Data([9, 0x91, 1, 7, 0, 8, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]),
                    Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0x30]),
                ], to: command, session: s)
            } catch { fail(s, "NSO initialization failed: \(error)") }
        }
    }

    static func matchesNSOManufacturer(_ bytes: [UInt8], includesCompanyID: Bool = true) -> Bool {
        let o = includesCompanyID ? 2 : 0
        guard bytes.count >= o + 7 else { return false }
        if includesCompanyID && Array(bytes.prefix(2)) != [0x53, 0x05] { return false }
        let pair = Array(bytes[(o + 3)..<(o + 7)])
        return pair == [0x7e, 0x05, 0x73, 0x20] || pair == [0x05, 0x7e, 0x20, 0x73]
    }
}

extension NintendoControllerManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scanIfRequested() }
        else {
            for s in Array(sessions.values) { fail(s, "Bluetooth unavailable (\(central.state.rawValue))") }
            candidates.removeAll()
            peripherals.removeAll()
        }
        onBluetoothStateChanged?(central.state)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard discoveryRequested else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let source: ControllerSource
        if services.contains(Self.bridgeService) { source = .wiiBridge }
        else if let manufacturer, Self.matchesNSOManufacturer(Array(manufacturer)) { source = .nsoGameCube }
        else { return }
        guard options.sources.contains(source) else { return }
        let candidate = ControllerCandidate(id: peripheral.identifier,
            name: source == .wiiBridge ? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Wii Remote Bridge") : "NSO GameCube Controller", source: source,
            rssi: RSSI.intValue)
        candidates[candidate.id] = candidate
        peripherals[candidate.id] = peripheral
        onDiscovered?(candidate)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let s = sessions[peripheral.identifier] else {
            central.cancelPeripheralConnection(peripheral); return
        }
        onDiagnostic?(peripheral.identifier, "BLE connected; discovering services")
        peripheral.discoverServices(s.candidate.source == .wiiBridge ? [Self.bridgeService] : nil)
        scanIfRequested()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let s = sessions[peripheral.identifier] else { return }
        fail(s, error?.localizedDescription ?? "Connection failed")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let s = sessions.removeValue(forKey: peripheral.identifier) else { return }
        s.writeRetry?.cancel()
        s.writes.disconnect()
        s.timeout?.cancel()
        peripheral.delegate = nil
        s.management?.disconnect()
        for remote in s.remotes.values { remote.disconnected() }
        onDiagnostic?(peripheral.identifier, error?.localizedDescription ?? "Peripheral disconnected")
        onConnectionChanged?(peripheral.identifier, error.map { .failed($0.localizedDescription) } ?? .disconnected)
        scanIfRequested()
    }
}

extension NintendoControllerManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        guard error == nil, let services = p.services, !services.isEmpty else {
            fail(s, error?.localizedDescription ?? "No controller services"); return
        }
        onDiagnostic?(p.identifier, "Discovering controller characteristics")
        s.pendingServices = Set(services)
        for service in services { p.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        guard error == nil else { fail(s, error!.localizedDescription); return }
        for c in service.characteristics ?? [] { s.characteristics[c.uuid] = c }
        s.pendingServices.remove(service)
        guard s.pendingServices.isEmpty else { return }
        let isBridge = s.candidate.source == .wiiBridge
        s.input = s.characteristics[isBridge ? Self.bridgeInput : Self.nsoInput]
        s.command = isBridge ? s.characteristics[Self.bridgeOutput]
            : (s.characteristics[Self.nsoBasic] ?? s.characteristics[Self.nsoCommand])
        guard let input = s.input, input.properties.contains(.notify), let command = s.command,
              command.properties.contains(.write) || command.properties.contains(.writeWithoutResponse) else {
            fail(s, "Required controller characteristics are missing"); return
        }
        var notifications = [input]
        if isBridge {
            guard let status = s.characteristics[Self.bridgeStatus],
                  status.properties.contains(.read), status.properties.contains(.notify) else {
                fail(s, "Required bridge status characteristic is missing"); return
            }
            notifications.append(status)
            if let control = s.characteristics[Self.bridgeControl],
               control.properties.contains(.write), (control.properties.contains(.notify) || control.properties.contains(.indicate)) {
                notifications.append(control)
                s.management = BridgeManagementSession(cancelQueued: { [weak s] requestID in
                    s?.writes.remove(kind: .management(requestID))
                }, transmit: { [weak self, weak s] data, completed in
                    guard let self, let s, s.ready else { throw BridgeManagementError.disconnected }
                    let b = Array(data)
                    let frames = try BridgeProtocol.fragments(slot: 0, sequence: UInt16(b[1]) | UInt16(b[2]) << 8, report: data)
                    self.onDiagnostic?(p.identifier, "Management \(b[3]) queued (\(s.writes.count) pending writes)")
                    try self.enqueue(frames, to: control, session: s,
                                     kind: .management(UInt16(b[1]) | UInt16(b[2]) << 8),
                                     result: { [weak s] result in
                        if case .failure(let error) = result { s?.management?.rejected(error) }
                    }) { [weak self] in
                        self?.onDiagnostic?(p.identifier, "Management \(b[3]) transmitted")
                        completed()
                    }
                })
            }
        } else {
            // Subscribe only to known Nintendo command channels, never arbitrary characteristics.
            notifications += [Self.nsoBasic, Self.nsoCommand].compactMap {
                guard let c = s.characteristics[$0], c.properties.contains(.notify) else { return nil }
                return c
            }
        }
        onDiagnostic?(p.identifier, "Subscribing to \(notifications.count) notification channels")
        s.pendingNotifications = Set(notifications)
        for c in notifications { p.setNotifyValue(true, for: c) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(s, error?.localizedDescription ?? "Controller notifications stopped"); return
        }
        onDiagnostic?(p.identifier, "Notifications active: \(characteristic.uuid.uuidString)")
        s.pendingNotifications.remove(characteristic)
        initializeIfReady(s)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        guard error == nil else { fail(s, error!.localizedDescription); return }
        guard let data = characteristic.value else { return }
        if s.candidate.source == .wiiBridge {
            if characteristic.uuid == CBUUID(string: BridgeProtocol.capabilitiesUUID) {
                guard data.count == 1 else { fail(s, "Invalid bridge capabilities"); return }
                s.capabilitiesPending = false
                s.playerStatusExpected = data[0] & 16 != 0
                if characteristic.properties.contains(.write) {
                    do {
                        let batch = options.batchInputReports && data[0] & 8 != 0
                        let mode: UInt8 = data[0] & 4 != 0 ? (batch ? 3 : 2) : 1
                        let requested = mode | (s.playerStatusExpected ? 0x80 : 0)
                        try enqueue([Data([requested])], to: characteristic, session: s, completed: { [weak s] in
                            guard let s, let status = s.characteristics[Self.bridgeStatus] else { return }
                            s.peripheral.readValue(for: status)
                        })
                        onDiagnostic?(p.identifier, "Input mode \(mode), stable player status=\(s.playerStatusExpected)")
                    } catch { fail(s, "Bridge input negotiation failed: \(error)") }
                }
            } else if characteristic.uuid == Self.bridgeControl {
                if let reply = s.controlAssembler.receive(data) {
                    onDiagnostic?(p.identifier, "Management reply \(reply.sequence)")
                    s.management?.receive(reply.data)
                }
            } else if characteristic.uuid == Self.bridgeStatus {
                guard let status = BridgeStatus(data: data) else {
                    fail(s, "Unsupported bridge protocol or invalid status"); return
                }
                let lostSlots = (s.status?.connectedSlots ?? []).subtracting(status.connectedSlots)
                s.status = status
                for slot in lostSlots { s.writes.remove(kind: .wii(slot), error: WiiRemoteError.disconnected) }
                for slot in Array(s.remotes.keys) where !status.connectedSlots.contains(slot) {
                    s.remotes.removeValue(forKey: slot)?.disconnected()
                }
                if s.initialized { markReady(s) }
                if s.ready { onBridgeStatus?(p.identifier, status) }
            } else if characteristic === s.input, s.ready {
                for report in s.assembler.receiveReports(data) {
                    s.remotes[report.slot]?.receive(report.data)
                    onWiiReport?(p.identifier, report)
                }
            }
        } else if characteristic === s.input, s.initialized, let state = s.decoder.decode(data) {
            markReady(s)
            onGameCubeInput?(p.identifier, state)
        }
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        // Only explicit ATT resource rejection is safe to replay. Transport failures
        // remain fatal; other ATT errors fail just their logical command.
        let nsError = error as NSError?
        if let nsError, nsError.domain != CBATTErrorDomain { fail(s, nsError.localizedDescription); return }
        let retryable = nsError?.code == CBATTError.insufficientResources.rawValue
        s.writes.acknowledge(destination: characteristic, error: error, retryable: retryable,
                             now: ProcessInfo.processInfo.systemUptime)
        drain(s)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard let s = sessions[p.identifier] else { return }
        drain(s)
    }
}
