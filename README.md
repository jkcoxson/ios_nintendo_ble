# NintendoBLE

NintendoBLE is a Swift package for connecting to Nintendo controllers from an app. It supports direct BLE connections to NSO GameCube controllers and a companion ESP32 bridge for Wii Remotes. The bridge firmware is written in Rust and forwards Wii HID reports over BLE.

The firmware targets the original ESP32 (including ESP32-WROOM-32D) with 4 MB flash. An ESP32-S3 cannot host Wii Remotes because it lacks Bluetooth Classic.

## Capabilities

- App-controlled discovery, connection, and reconnection through CoreBluetooth. The package never connects to an advertisement automatically.
- NSO GameCube buttons, sticks, analog triggers, battery, player LEDs, and rumble.
- Up to seven remembered Wii Remotes per bridge, with four connected at once, plus pairing, persistent names, player ordering, and individual remote controls.
- Raw, bidirectional Wii HID reports, including extension, MotionPlus, memory, IR, and speaker traffic. Optional Swift helpers decode buttons, acceleration, and IR, and provide calibration, IR setup, LEDs, and rumble.
- Timestamped and batched Wii input on capable firmware, with fallback to older BLE frame formats.

The raw Wii channel carries complete reports; apps must implement any extension or MotionPlus decoding they need. IR points are sensor coordinates and require a sensor bar or other IR reference. The bridge accepts one BLE app at a time and does not require BLE bonding or encryption.

## Use the Swift package

Add this directory as a local Swift Package dependency in Xcode and link `NintendoBLE`. The minimum platforms are iOS 14 and macOS 13. Add `NSBluetoothAlwaysUsageDescription` to the host app's Info.plist. Sandboxed macOS apps also need the Bluetooth entitlement.

Own `NintendoControllerManager` for the session. Its operations and callbacks run on the main actor. Show discovered candidates in your own picker, then connect only after selection:

```swift
import NintendoBLE

@MainActor
final class ControllerPicker {
    let manager = NintendoControllerManager()

    func start() {
        manager.onDiscovered = { candidate in
            // Show candidate.id, candidate.name, and candidate.source.
        }
        manager.onGameCubeInput = { id, state in
            // Map buttons, sticks, and triggers to your app's input model.
        }
        manager.onWiiReport = { bridgeID, report in
            // report.slot identifies the remote; report.data is HID ID + payload.
            // WiiInput(report: report.data) provides optional basic decoding.
        }
        manager.startDiscovery()
    }

    func select(_ candidate: ControllerCandidate) throws {
        try manager.connect(to: candidate.id)
    }
}
```

For a saved bridge, call `prepareBluetooth()`, wait for `.poweredOn`, then call `connectToKnownBridge(id:name:)`. If the identifier is no longer known to the OS, scan again. Call `stopDiscovery()` when the picker closes and `disconnect(_:)` or `stop()` when done. Apps should clear held input when a connection or Wii slot disappears, and apply their own stale-input timeout.

After the bridge reaches `.ready`, check `supportsBridgeManagement(_:)` before using management commands:

```swift
let info = try await manager.bridgeInfo(via: bridgeID)
try await manager.openPairingWindow(via: bridgeID)
try await manager.renameBridge("Living Room", via: bridgeID)
let remote = try await manager.remoteInfo(slot: 0, via: bridgeID)
try await manager.renameRemote(remote, name: "Blue Remote", via: bridgeID)
```

`supportsRemoteControl(_:)` identifies firmware with `playerState(via:)`, `setPlayerOrder(_:via:)`, `disconnectRemote(_:via:)`, and `connectRemote(_:via:)`. Player ports can have gaps when remotes disconnect; preserve the order in `BridgeStatus.playerOrder`. Remote addresses are stable identities; slot assignments and player ports can change.

Use `wiiRemote(slot:via:)` for optional acceleration calibration and IR initialization, or `sendWiiReport(_:slot:via:)` for raw commands. Reports include the HID report ID and omit the Bluetooth `0xA1` input or `0xA2` output prefix. Keep the rumble bit in the first output payload byte when constructing commands. See [PROTOCOL.md](PROTOCOL.md) for framing and capability details.

## Pair a Wii Remote

1. Power the bridge with no remembered remotes, or call `openPairingWindow(via:)` from a connected app.
2. Within 30 seconds, press the red **SYNC** button under the remote's battery cover. The 1+2 guest pairing procedure is unsupported.
3. Later, wake the remembered remote with a normal button press. It initiates reconnection to the bridge.

The bridge remembers up to seven remotes across reboots. Pair additional remotes while fewer than four are connected. A remembered remote can take a free live slot when it wakes, and its saved name follows its Bluetooth address. Once four remotes are connected, further connections wait until a slot is free. To forget remotes after the roster fills, clear the bridge's NVS partition deliberately. The firmware recognizes `Nintendo RVL-CNT-01` and `Nintendo RVL-CNT-01-TR`; other models and four simultaneous remotes need hardware validation.

## Build and flash the bridge

Install the Espressif Rust `esp` toolchain with `espup`, plus `ldproxy`, `espflash`, Python 3, CMake, and Ninja. Source the environment file generated by `espup`, then build from `firmware/` so its toolchain and Cargo configuration apply:

```sh
source /path/to/export-esp.sh # Use the environment file generated by espup.
cd firmware
cargo build --release --locked
cd ..
sh Tools/flash.sh /dev/cu.usbserial-PORT
```

Use your board's actual serial port. The flash script builds and flashes the bootloader, partition table, and application, then opens a serial monitor. Normal flashing preserves NVS and existing bonds.

## Verify

```sh
swift test
rustc --edition=2021 --test firmware/src/protocol.rs -o /tmp/nintendo-bridge-protocol-tests
/tmp/nintendo-bridge-protocol-tests
```

`Tools/Probe.swift` is a macOS hardware probe source for discovery, Wii setup, management, and report capture. It requires a macOS app build and an explicit `--connect <UUID>` to connect. Its optional `--test-extensions` mode requires a separately linked implementation of the `probe_extension_*` functions; the Swift package itself has no extension decoder dependency. Captures can be summarized with `python3 Tools/analyze-capture.py capture.log`.

## References

`NSOInputDecoder.swift` adapts the decoder and calibration logic from `nso_gc_driver` (MIT licensed), including Nintendo BLE UUIDs and commands. Wii wire layouts and setup sequences follow [WiiBrew's protocol research](https://wiibrew.org/wiki/Wiimote). The firmware uses [ESP-IDF](https://github.com/espressif/esp-idf) and [esp-idf-svc](https://github.com/esp-rs/esp-idf-svc).

## License

MIT. See [LICENSE](LICENSE).
