import Foundation

private func log(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

#if WII_EXTENSION_PROBE
@_silgen_name("probe_extension_receive") func extensionReceive(_ slot: UInt8, _ data: UnsafePointer<UInt8>, _ length: Int, _ now: UInt64)
@_silgen_name("probe_extension_command") func extensionCommand(_ slot: UInt8, _ data: UnsafeMutablePointer<UInt8>, _ now: UInt64) -> Int
@_silgen_name("probe_extension_reset") func extensionReset(_ slot: UInt8)
@_silgen_name("probe_extension_sent") func extensionSent(_ slot: UInt8)
@_silgen_name("probe_extension_state") func extensionState(_ slot: UInt8) -> UInt8
#endif

/// Local hardware smoke test. Scanning alone never connects; pass a discovered UUID explicitly.
@main
@MainActor
struct Probe {
    @MainActor private final class RunState {
        var extensionStarted = Set<UInt8>()
        var setupRunning = false
        var extensionPending: [UInt8: UUID] = [:]
        var liveSlots = Set<UInt8>()
        var stressQueued = 0
        var stressRejected = 0
    }

    static func main() {
        let args = CommandLine.arguments
#if !WII_EXTENSION_PROBE
        if args.contains("--test-extensions") {
            log("Extension testing requires a probe build linked with a compatible probe_extension_* implementation")
            return
        }
#endif
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let selected = argument("--connect").flatMap(UUID.init(uuidString:))
        let duration = argument("--seconds").flatMap(Double.init) ?? 15
        let manager = NintendoControllerManager(options: .init(batchInputReports: !args.contains("--no-batch")))
        var attempted = false
        var reports = 0
        var previousStatus: BridgeStatus?
        var tested = false
        var testedManagement = false
        var connectionReady = false
        var lastIRLog = Date.distantPast
        let started = ProcessInfo.processInfo.systemUptime
        var initializedSlots = Set<UInt8>()
        let run = RunState()
        var arrivals: [UInt8: [Double]] = [:]
        var sourceGaps: [UInt8: [Double]] = [:]
        var lastSource: [UInt8: UInt32] = [:]
        var extensionTimer: Timer?
        var stressTimer: Timer?
        if args.contains("--stress-output"), let selected {
            // Deliberately exceed ordinary command traffic for fifteen seconds,
            // then allow queues to drain. Status requests do not activate rumble.
            stressTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
                Task { @MainActor in
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    guard (60..<75).contains(elapsed) else { return }
                    for slot in run.liveSlots.sorted() {
                        do {
                            try manager.sendWiiReport(Data([0x15, 0]), slot: slot, via: selected)
                            run.stressQueued += 1
                        } catch { run.stressRejected += 1 }
                    }
                }
            }
        }
#if WII_EXTENSION_PROBE
        if args.contains("--test-extensions"), let selected {
            extensionTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
                Task { @MainActor in
                    for slot in run.extensionStarted.sorted() {
                        // Do not interleave extension commands with high-level IR setup.
                        guard !run.setupRunning, run.extensionPending[slot] == nil else { continue }
                        var bytes = [UInt8](repeating: 0, count: 22)
                        let count = extensionCommand(slot, &bytes, UInt64((ProcessInfo.processInfo.systemUptime - started) * 1000))
                        if count > 0 {
                            do {
                                let token = UUID()
                                run.extensionPending[slot] = token
                                try manager.sendWiiReport(Data(bytes.prefix(count)), slot: slot, via: selected) { result in
                                    guard run.extensionPending[slot] == token else { return }
                                    run.extensionPending.removeValue(forKey: slot)
                                    if case .success = result { extensionSent(slot) }
                                    else { log("EXT output rejected slot=\(slot): \(result)") }
                                }
                            } catch { run.extensionPending.removeValue(forKey: slot); log("EXT output slot=\(slot): \(error)") }
                        }
                    }
                }
            }
        }
#endif
        manager.onWiiOutputError = { _, slot, error in log("OUTPUT ERROR slot=\(slot): \(error)") }
        manager.onBluetoothStateChanged = { state in log("Bluetooth state: \(state.rawValue)") }
        manager.onDiscovered = { candidate in
            log("Candidate \(candidate.id) \(candidate.source) RSSI=\(candidate.rssi)")
            if candidate.id == selected, !attempted {
                attempted = true
                do { try manager.connect(to: candidate.id) }
                catch { log("Connect error: \(error)") }
            }
        }
        manager.onDiagnostic = { id, text in log("Diagnostic \(id): \(text)") }
        manager.onConnectionChanged = { id, state in
            log("Connection \(id): \(state)")
            connectionReady = state == .ready
            if state == .ready, args.contains("--test-players"), !testedManagement {
                testedManagement = true
                Task { @MainActor in
                    var original: BridgePlayerState?
                    var disconnectedRemote: BridgeDeviceInfo?
                    do {
                        try await Task.sleep(for: .seconds(argument("--player-wait").flatMap(Double.init) ?? 35))
                        for _ in 0..<220 {
                            if previousStatus?.connectedSlots.isEmpty == false { break }
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        log("Testing player commands with live slots \(previousStatus?.connectedSlots.sorted() ?? [])")
                        let initial = try await manager.playerState(via: id)
                        log("Initial player state: \(initial.order)")
                        original = initial
                        var identities: [BridgeDeviceInfo] = []
                        for slot: UInt8 in 0..<4 {
                            do { identities.append(try await manager.remoteInfo(slot: slot, via: id)); log("Read identity for slot \(slot)") }
                            catch BridgeManagementError.rejected(2) { continue }
                        }
                        let order = Array(initial.order.reversed())
                        let changed = try await manager.setPlayerOrder(order, via: id)
                        guard changed.order == order else { throw BridgeManagementError.invalidResponse }
                        for remote in identities {
                            let current = try await manager.remoteInfo(slot: remote.target, via: id)
                            guard current == remote else { throw BridgeManagementError.invalidResponse }
                        }
                        log("Player order changed to \(order); remote identities/names unchanged")
                        manager.disconnect(id)
                        try await Task.sleep(for: .seconds(2))
                        try manager.connectToKnownBridge(id: id, name: "WiiBLE")
                        for _ in 0..<100 {
                            if connectionReady { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let retained = try await manager.playerState(via: id)
                        guard retained.order == order else { throw BridgeManagementError.invalidResponse }
                        _ = try await manager.setPlayerOrder(initial.order, via: id)
                        log("Player order PASS: runtime order survives BLE reconnect, original order restored")
                        let liveSlot = previousStatus?.connectedSlots.sorted().last
                        if let remote = identities.first(where: { $0.target == liveSlot }) ?? identities.last {
                            let slot = remote.target
                            disconnectedRemote = remote
                            let others = (previousStatus?.connectedSlots ?? []).subtracting([slot])
                            try await manager.disconnectRemote(remote, via: id)
                            try await Task.sleep(for: .seconds(6))
                            let suspended = try await manager.playerState(via: id)
                            guard suspended.disconnectedSlots.contains(slot),
                                  previousStatus?.connectedSlots.contains(slot) == false,
                                  others.isSubset(of: previousStatus?.connectedSlots ?? []), connectionReady else {
                                throw BridgeManagementError.invalidResponse
                            }
                            try await manager.connectRemote(remote, via: id)
                            let resumed = try await manager.playerState(via: id)
                            guard !resumed.disconnectedSlots.contains(slot) else { throw BridgeManagementError.invalidResponse }
                            log("Remote control PASS: slot stayed disconnected, bridge/other slots stayed connected, reconnect resumed; live HID disconnect exercised=\(liveSlot != nil)")
                            disconnectedRemote = nil
                        } else { log("No remembered remote: disconnect command needs a live test") }
                    } catch { log("Player control FAILED: \(error)") }
                    if let original { _ = try? await manager.setPlayerOrder(original.order, via: id) }
                    if let remote = disconnectedRemote { try? await manager.connectRemote(remote, via: id) }
                }
            }
            if state == .ready, args.contains("--test-management"), !testedManagement {
                testedManagement = true
                Task { @MainActor in
                    var originalBridge: BridgeDeviceInfo?
                    var originalRemote: BridgeDeviceInfo?
                    do {
                        // Exercise the closed -> open transition after the boot pairing window.
                        try await Task.sleep(for: .seconds(35))
                        let bridge = try await manager.bridgeInfo(via: id)
                        originalBridge = bridge
                        log("Management bridge name: \(bridge.name)")
                        for slot: UInt8 in 0..<4 {
                            do {
                                let remote = try await manager.remoteInfo(slot: slot, via: id)
                                log("Remembered remote \(slot): \(remote.name), identity=\(remote.address as NSData)")
                                if originalRemote == nil { originalRemote = remote }
                            } catch BridgeManagementError.rejected(2) { continue }
                        }
                        try await manager.openPairingWindow(via: id)
                        log("Pairing reopen confirmed")
                        try await manager.renameBridge("WiiBLE test", via: id)
                        if let remote = originalRemote { try await manager.renameRemote(remote, name: "Remote test", via: id) }
                        manager.disconnect(id)
                        try await Task.sleep(for: .seconds(2))
                        try manager.connectToKnownBridge(id: id, name: "WiiBLE test")
                        for _ in 0..<100 {
                            if connectionReady { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let renamed = try await manager.bridgeInfo(via: id)
                        guard renamed.name == "WiiBLE test" else { throw BridgeManagementError.invalidResponse }
                        if let remote = originalRemote {
                            let renamedRemote = try await manager.remoteInfo(slot: remote.target, via: id)
                            guard renamedRemote.name == "Remote test", renamedRemote.address == remote.address else {
                                throw BridgeManagementError.invalidResponse
                            }
                            try await manager.renameRemote(remote, name: remote.name, via: id)
                        }
                        try await manager.renameBridge(bridge.name, via: id)
                        log("Management PASS: pairing, bridge/remote names, remembered identity reconnect; original names restored")
                    } catch {
                        log("Management FAILED: \(error)")
                        if let bridge = originalBridge { try? await manager.renameBridge(bridge.name, via: id) }
                        if let remote = originalRemote { try? await manager.renameRemote(remote, name: remote.name, via: id) }
                    }
                }
            }
        }
        manager.onBridgeStatus = { id, status in
            for slot in run.liveSlots.subtracting(status.connectedSlots) {
                initializedSlots.remove(slot)
                run.extensionStarted.remove(slot)
                run.extensionPending.removeValue(forKey: slot)
#if WII_EXTENSION_PROBE
                extensionReset(slot)
#endif
            }
            run.liveSlots = status.connectedSlots
            if status != previousStatus {
                log("Bridge pairing=\(status.pairingOpen) slots=\(status.connectedSlots.sorted()) players=\(status.playerOrder ?? [])")
                previousStatus = status
            }
            // A status notification may arrive before characteristic setup is
            // complete. Do not mark commands as started when send would fail.
            guard connectionReady else { return }
            var setupCandidates = status.connectedSlots.subtracting(initializedSlots)
#if WII_EXTENSION_PROBE
            if args.contains("--test-extensions") {
                for slot in status.connectedSlots.subtracting(run.extensionStarted) {
                    run.extensionStarted.insert(slot)
                    try? manager.sendWiiReport(Data([0x15, 0]), slot: slot, via: id)
                }
                setupCandidates = setupCandidates.filter { extensionState($0) & 1 != 0 }
            }
#endif
            if args.contains("--test-all"), !run.setupRunning,
               let slot = setupCandidates.sorted().first {
                run.setupRunning = true
                initializedSlots.insert(slot)
                Task { @MainActor in
                    defer { run.setupRunning = false }
                    do {
                        let remote = try manager.wiiRemote(slot: slot, via: id)
                        _ = try await remote.loadAccelerationCalibration()
                        try await remote.enableIR(includeExtension: args.contains("--extension-bytes") || args.contains("--test-extensions"))
                        log("SETUP slot=\(slot) IR acknowledged")
#if WII_EXTENSION_PROBE
                        if args.contains("--test-extensions") { log("EXT slot=\(slot) state=\(extensionState(slot)) (ready=1, MotionPlus=2, factory=4, extension=8)") }
#endif
                    } catch { log("SETUP slot=\(slot) failed: \(error)") }
                }
            }
            if args.contains("--test-wii"), !tested, let slot = status.connectedSlots.sorted().first {
                tested = true
                Task { @MainActor in
                    do {
                        let remote = try manager.wiiRemote(slot: slot, via: id)
                        try remote.setRumble(true)
                        try await Task.sleep(for: .milliseconds(200))
                        try remote.setRumble(false)
                        let calibration = try await remote.loadAccelerationCalibration()
                        log("Wii EEPROM calibration read and checksum verified: \(calibration)")
                        try await remote.enableIR()
                        log("Wii IR initialization acknowledged; mode 0x33 enabled")
                    } catch { log("Wii command test failed: \(error)") }
                }
            }
        }
        manager.onWiiReport = { _, report in
            reports += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - started
#if WII_EXTENSION_PROBE
            if args.contains("--test-extensions") {
                report.data.withUnsafeBytes { extensionReceive(report.slot, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count, UInt64(elapsed * 1000)) }
                // Restore the report mode after extension reinitialization, even
                // when the Bluetooth link stays connected.
                if extensionState(report.slot) & 1 == 0, initializedSlots.remove(report.slot) != nil {
                    log("EXT restarted slot=\(report.slot); IR will be restored when ready")
                }
            }
#endif
            if (report.data.first ?? 0) >= 0x30 {
                arrivals[report.slot, default: []].append(elapsed)
                if let timestamp = report.timestampMicroseconds {
                    if let previous = lastSource[report.slot] {
                        sourceGaps[report.slot, default: []].append(Double(timestamp &- previous) / 1000)
                    }
                    lastSource[report.slot] = timestamp
                }
            }
            if args.contains("--capture") {
                log("REPORT t=\(elapsed) slot=\(report.slot) seq=\(report.sequence) us=\(report.timestampMicroseconds.map(String.init) ?? "none") data=\(report.data.map { String(format: "%02x", $0) }.joined())")
            }
            if args.contains("--test-ir"), Date().timeIntervalSince(lastIRLog) >= 0.1,
               let input = WiiInput(report: report.data), !input.irPoints.isEmpty {
                lastIRLog = Date()
                log("IR slot=\(report.slot) points=\(input.irPoints) accel=\(String(describing: input.acceleration))")
            }
            if reports <= 5 || reports % 100 == 0 {
                log("Wii input #\(reports) slot=\(report.slot) \(report.data.map { String(format: "%02x", $0) }.joined())")
            }
        }
        manager.onGameCubeInput = { _, state in
            reports += 1
            if reports <= 5 || reports % 100 == 0 { log("NSO input #\(reports): \(state.buttons)") }
        }
        manager.startDiscovery()
        RunLoop.main.run(until: Date().addingTimeInterval(max(1, duration)))
        extensionTimer?.invalidate()
        stressTimer?.invalidate()
        if args.contains("--stress-output") { log("OUTPUT STRESS queued=\(run.stressQueued) rejected=\(run.stressRejected)") }
        manager.stop()
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "no intervals" }
            return String(format: "p95=%.2f max=%.2f ms", sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!)
        }
        for slot in arrivals.keys.sorted() {
            let times = arrivals[slot]!
            let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
            let span = (times.last ?? 0) - (times.first ?? 0)
            log("SUMMARY slot=\(slot) reports=\(times.count) rate=\(Double(max(0, times.count - 1)) / max(0.001, span)) arrival \(summary(gaps)) source \(summary(sourceGaps[slot] ?? []))")
        }
        log("Finished: \(reports) input reports")
    }
}
