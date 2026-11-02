// Adapted from nso_gc_driver (MIT), Sources/NSOGCDriver/Driver.swift.
import Foundation

/// Power information included in the NSO controller's 0x0A input report.
/// The hardware reports ten discrete levels (0...9), so the percentage is
/// necessarily an approximation rather than a continuous measurement.
struct ControllerBattery: Equatable {
  let level: Int
  let isCharging: Bool
  let hasExternalPower: Bool

  init?(powerInfo: UInt8) {
    let reportedLevel = Int((powerInfo >> 2) & 0x0f)
    guard reportedLevel <= 9 else { return nil }
    level = reportedLevel
    isCharging = powerInfo & 0x02 != 0
    hasExternalPower = powerInfo & 0x01 != 0
  }

  var percentage: Int {
    Int((Double(level) * 100.0 / 9.0).rounded())
  }
}

struct ControllerState: Equatable {
  var buttons: [String: Bool] = [:]
  var leftX = 0, leftY = 0, rightX = 0, rightY = 0
  var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
  var battery: ControllerBattery?
  var raw = [UInt8]()

  // Raw reports may contain transport counters or unrelated status bytes that
  // change even when the controls do not. Only decoded controls and battery
  // state participate in equality, avoiding unchanged input updates while
  // still publishing power changes.
  static func == (lhs: ControllerState, rhs: ControllerState) -> Bool {
    lhs.buttons == rhs.buttons
      && lhs.leftX == rhs.leftX && lhs.leftY == rhs.leftY
      && lhs.rightX == rhs.rightX && lhs.rightY == rhs.rightY
      && lhs.leftTrigger == rhs.leftTrigger && lhs.rightTrigger == rhs.rightTrigger
      && lhs.battery == rhs.battery
  }
}

final class InputDecoder {
  var center = (x: 2048, y: 2048, cx: 2048, cy: 2048)
  private var calibrationSamples: [(Int, Int, Int, Int)] = []
  private var calibrationReportsToSkip = 5
  private var leftStickDeadzone = 24
  private var rightStickDeadzone = 24
  private var bleHasReportID: Bool?
  private var sawAmbiguousBLEReport = false
  private var leftTriggerFilter = TriggerFilter()
  private var rightTriggerFilter = TriggerFilter()

  // Calibrate the trigger's nonzero rest point without delaying input by a
  // report. Its raw value is reported immediately after normalization.
  private struct TriggerFilter {
    private var releasedSamples: [Int] = []
    private var zero = 0x24
    private var maximum = 0xc0

    mutating func apply(raw: UInt8, digitalPressed: Bool) -> UInt8 {
      let value = Int(raw)

      // The raw trigger does not start at zero and its rest point varies
      // per controller. Learn that point only from low, unclicked samples.
      if !digitalPressed && value < 0x70 && releasedSamples.count < 32 {
        releasedSamples.append(value)
        if releasedSamples.count >= 8 {
          // A low percentile learns the real rest point even if the
          // user lightly holds the trigger during some early reports.
          let sorted = releasedSamples.sorted()
          zero = sorted[sorted.count / 5]
        }
      }
      maximum = max(maximum, value)

      // Leave a few raw counts for sensor noise at the released end, then
      // expand the usable travel to the full 8-bit output range.
      let floor = zero + 4
      let normalized: Int
      if value <= floor || maximum <= floor {
        normalized = 0
      } else {
        normalized = min(255, (value - floor) * 255 / (maximum - floor))
      }

      return UInt8(normalized)
    }
  }

  func decode(_ data: [UInt8], bluetooth: Bool = false, offset: Int = 0) -> ControllerState? {
    guard offset >= 0 else { return nil }
    // macOS may remove the HID report ID, leaving the native BLE report at
    // 11 bytes. USB and full BLE reports are longer.
    guard data.count >= (bluetooth ? 11 : 15) + offset else { return nil }
    let o = offset
    // The common 63-byte BLE notification is ID-stripped. Lock the layout
    // for the connection instead of re-deciding from byte 0, which is a
    // rolling counter and can occasionally equal report ID 0x30.
    let fullBLEReport: Bool
    if bluetooth, data[0] != 0x3f || data.count != 12 {
      if let knownLayout = bleHasReportID {
        fullBLEReport = knownLayout
      } else if data.count == 63 || data[0] != 0x30 {
        if data.count >= 63 { bleHasReportID = false }
        fullBLEReport = false
      } else if data.count < 16 {
        fullBLEReport = false
      } else if !sawAmbiguousBLEReport {
        // One 0x30-valued counter sample is not enough to conclude
        // that a report ID is present. Skip this startup sample only.
        sawAmbiguousBLEReport = true
        return nil
      } else {
        bleHasReportID = true
        fullBLEReport = true
      }
    } else {
      fullBLEReport = false
    }
    // Report 0x0A stores Power Info after its rolling counter. USB includes
    // the report ID at byte 0; CoreBluetooth normally strips that ID. The
    // legacy 12-byte 0x3f report has no battery field.
    let isLegacySimpleReport = bluetooth && data.count == 12 && data[0] == 0x3f
    let powerInfoIndex = (bluetooth && !fullBLEReport ? 1 : 2) + o
    let battery =
      !isLegacySimpleReport && data.indices.contains(powerInfoIndex)
      ? ControllerBattery(powerInfo: data[powerInfoIndex]) : nil
    var buttons: [String: Bool] = [:]
    if bluetooth {
      // Short 0x3f reports use 16-bit axes and have a different button
      // layout from the normal 0x30 report.
      if data.count >= 63 && !fullBLEReport {
        // Discovered NSO BLE report: buttons are in the USB-style
        // order B, A, Y, X at bytes 2-4; sticks begin at byte 5.
        let b2 = data[2 + o]
        let b3 = data[3 + o]
        let b4 = data[4 + o]
        buttons = [
          "B": b2 & 1 != 0, "A": b2 & 2 != 0, "Y": b2 & 4 != 0, "X": b2 & 8 != 0,
          "R": b2 & 0x10 != 0, "Z": b2 & 0x20 != 0, "Start": b2 & 0x40 != 0,
          "Dpad_Down": b3 & 1 != 0, "Dpad_Right": b3 & 2 != 0,
          "Dpad_Left": b3 & 4 != 0, "Dpad_Up": b3 & 8 != 0,
          "L": b3 & 0x10 != 0, "ZL": b3 & 0x20 != 0,
          "Home": b4 & 1 != 0, "Capture": b4 & 2 != 0,
        ]
      } else if data[0] == 0x3f {
        guard data.count >= 12 + offset else { return nil }
        let b1 = data[1 + offset]
        let b2 = data[2 + offset]
        let buttons: [String: Bool] = [
          "Dpad_Down": b1 & 1 != 0, "Dpad_Right": b1 & 2 != 0,
          "Dpad_Left": b1 & 4 != 0, "Dpad_Up": b1 & 8 != 0,
          "Start": b2 & 2 != 0, "Home": b2 & 0x10 != 0,
          "Capture": b2 & 0x20 != 0, "L": b2 & 0x40 != 0,
          "Z": b2 & 0x80 != 0, "Y": false, "X": false,
          "B": false, "A": false, "R": false, "ZL": false,
        ]
        func wideAxis(_ i: Int) -> (Int, Int) {
          (
            Int(data[i + o]) | Int(data[i + 1 + o]) << 8,
            Int(data[i + 2 + o]) | Int(data[i + 3 + o]) << 8
          )
        }
        let main = wideAxis(4)
        let right = wideAxis(8)
        return condition(
          buttons: buttons, main: (main.0 - 32768, main.1 - 32768),
          right: (right.0 - 32768, right.1 - 32768),
          rawLeftTrigger: b2 & 0x40 != 0 ? 255 : 0,
          rawRightTrigger: b2 & 0x80 != 0 ? 255 : 0, battery: nil, raw: data,
          triggersAreAnalog: false)
      }
      // CoreBluetooth commonly strips the HID report ID. The Python bridge
      // handled both full 0x30 reports and the shortened 11-byte form.
      // Long BLE notifications have already had their HID report ID
      // removed. Byte 0 is a rolling counter, which can itself become
      // 0x30; never treat that counter value as a layout switch.
      let stripped = !fullBLEReport
      let buttonBase = stripped ? 2 : 3
      let b3 = data[buttonBase + o]
      let b4 = data[buttonBase + 1 + o]
      let b5 = data[buttonBase + 2 + o]
      if data.count >= 63 && !fullBLEReport {
        // Already decoded above.
      } else if data[0] == 0x3f {
        buttons = [
          "B": b3 & 1 != 0, "A": b3 & 2 != 0, "Y": b3 & 4 != 0, "X": b3 & 8 != 0,
          "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b3 & 0x40 != 0,
          "Dpad_Down": b4 & 1 != 0, "Dpad_Right": b4 & 2 != 0, "Dpad_Left": b4 & 4 != 0,
          "Dpad_Up": b4 & 8 != 0, "L": b4 & 0x10 != 0, "ZL": b4 & 0x20 != 0,
          "Home": b5 & 1 != 0, "Capture": b5 & 2 != 0,
        ]
      } else {
        buttons = [
          "Y": b3 & 1 != 0, "X": b3 & 2 != 0, "B": b3 & 4 != 0, "A": b3 & 8 != 0,
          "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b4 & 2 != 0,
          "Dpad_Down": b5 & 1 != 0, "Dpad_Up": b5 & 2 != 0, "Dpad_Right": b5 & 4 != 0,
          "Dpad_Left": b5 & 8 != 0, "L": b5 & 0x40 != 0, "ZL": b5 & 0x80 != 0,
          "Home": b4 & 0x10 != 0, "Capture": b4 & 0x20 != 0,
        ]
      }
    } else {
      let b3 = data[3 + o]
      let b4 = data[4 + o]
      let b5 = data[5 + o]
      buttons = [
        "B": b3 & 1 != 0, "A": b3 & 2 != 0, "Y": b3 & 4 != 0, "X": b3 & 8 != 0,
        "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b3 & 0x40 != 0,
        "Dpad_Down": b4 & 1 != 0, "Dpad_Right": b4 & 2 != 0, "Dpad_Left": b4 & 4 != 0,
        "Dpad_Up": b4 & 8 != 0, "L": b4 & 0x10 != 0, "ZL": b4 & 0x20 != 0,
        "Home": b5 & 1 != 0, "Capture": b5 & 2 != 0,
      ]
    }
    let strippedBLE = bluetooth && !fullBLEReport
    let stickBase = strippedBLE ? 5 : 6
    // The USB report includes the report ID at byte 0, so its payload is
    // shifted by one byte relative to the native BLE report. The payload
    // layout is: 3 button bytes, 3-byte left stick, 3-byte right stick,
    // one status byte, then the L/R analog triggers. Therefore the USB
    // trigger bytes are 13/14, not 14/15. BLE's long 0x0A report uses
    // bytes 12/13; the shorter BLE form uses 13/14.
    let triggerBase = strippedBLE ? (data.count >= 63 ? 12 : 13) : 13
    func axis(_ i: Int) -> (Int, Int) {
      let x = Int(data[i + o]) | (Int(data[i + 1 + o] & 0x0f) << 8)
      let y = Int(data[i + 1 + o] >> 4) | (Int(data[i + 2 + o]) << 4)
      return (x, y)
    }
    guard data.count >= stickBase + 6 + o else { return nil }
    let main = axis(stickBase)
    let right = axis(stickBase + 3)
    // The octagonal gate cannot put both axes of either stick near the
    // electrical minimum at once. Zero-filled or misaligned reports can,
    // and would otherwise map to a simultaneous bottom-left jump.
    guard !(main.0 < 128 && main.1 < 128),
      !(right.0 < 128 && right.1 < 128)
    else { return nil }
    calibrate(main: main, right: right)
    let hasAnalogTriggers = data.count >= triggerBase + 2 + o
    return condition(
      buttons: buttons, main: (main.0 - center.x, main.1 - center.y),
      right: (right.0 - center.cx, right.1 - center.cy),
      rawLeftTrigger: hasAnalogTriggers ? data[triggerBase + o] : 0,
      rawRightTrigger: hasAnalogTriggers ? data[triggerBase + 1 + o] : 0,
      battery: battery, raw: data, triggersAreAnalog: hasAnalogTriggers)
  }

  private func calibrate(main: (Int, Int), right: (Int, Int)) {
    guard calibrationSamples.count < 50 else { return }
    if calibrationReportsToSkip > 0 {
      calibrationReportsToSkip -= 1
      return
    }

    // Startup reports can arrive while a stick is being moved. Only use
    // samples plausibly close to the nominal 12-bit center, and use medians
    // so an isolated bad report cannot drag the learned center away.
    guard distance(main.0 - 2048, main.1 - 2048) < 256,
      distance(right.0 - 2048, right.1 - 2048) < 256
    else { return }
    calibrationSamples.append((main.0, main.1, right.0, right.1))
    guard calibrationSamples.count == 50 else { return }

    center = (
      median(calibrationSamples.map { $0.0 }),
      median(calibrationSamples.map { $0.1 }),
      median(calibrationSamples.map { $0.2 }),
      median(calibrationSamples.map { $0.3 })
    )
    let leftNoise = calibrationSamples.map { distance($0.0 - center.x, $0.1 - center.y) }
    let rightNoise = calibrationSamples.map { distance($0.2 - center.cx, $0.3 - center.cy) }
    leftStickDeadzone = learnedDeadzone(leftNoise)
    rightStickDeadzone = learnedDeadzone(rightNoise)
  }

  private func condition(
    buttons: [String: Bool], main: (Int, Int), right: (Int, Int),
    rawLeftTrigger: UInt8, rawRightTrigger: UInt8, battery: ControllerBattery?, raw: [UInt8],
    triggersAreAnalog: Bool = true
  ) -> ControllerState {
    let left = conditionStick(main, deadzone: leftStickDeadzone)
    let right = conditionStick(right, deadzone: rightStickDeadzone)
    return ControllerState(
      buttons: buttons, leftX: left.0, leftY: left.1,
      rightX: right.0, rightY: right.1,
      leftTrigger: triggersAreAnalog
        ? leftTriggerFilter.apply(raw: rawLeftTrigger, digitalPressed: buttons["L"] == true)
        : (buttons["L"] == true ? 255 : 0),
      rightTrigger: triggersAreAnalog
        ? rightTriggerFilter.apply(raw: rawRightTrigger, digitalPressed: buttons["R"] == true)
        : (buttons["R"] == true ? 255 : 0),
      battery: battery, raw: raw)
  }

  private func conditionStick(_ stick: (Int, Int), deadzone: Int) -> (Int, Int) {
    let magnitude = distance(stick.0, stick.1)
    guard magnitude > deadzone else { return (0, 0) }

    // Remove only the measured center-noise radius, then stretch the rest
    // of the travel slightly so the gate does not cost fine control or range.
    let expectedRange = 1400.0
    let adjustedMagnitude =
      (Double(magnitude - deadzone) * expectedRange)
      / max(1, expectedRange - Double(deadzone))
    let scale = adjustedMagnitude / Double(magnitude)
    return (
      Int((Double(stick.0) * scale).rounded()),
      Int((Double(stick.1) * scale).rounded())
    )
  }

  private func learnedDeadzone(_ noise: [Int]) -> Int {
    let sorted = noise.sorted()
    let percentile95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    return min(64, max(24, percentile95 + 8))
  }

  private func distance(_ x: Int, _ y: Int) -> Int {
    Int(hypot(Double(x), Double(y)).rounded())
  }

  private func median(_ values: [Int]) -> Int {
    values.sorted()[values.count / 2]
  }
}


/// A decoder is per controller/connection because stick and trigger calibration is learned.
/// This supports the observed native 63-byte NSO BLE report and its 64-byte HID form.
/// Unknown layouts are rejected, never guessed from a rolling counter.
public final class NSOGameCubeDecoder {
    private let decoder = InputDecoder()
    public init() {}

    public func decode(_ data: Data) -> GameCubeState? {
        var bytes = Array(data)
        if bytes.count == 64, bytes.first == 0x0a { bytes.removeFirst() }
        guard bytes.count == 63, let state = decoder.decode(bytes, bluetooth: true) else {
            return nil
        }
        let names: [String: GameCubeButton] = [
            "A": .a, "B": .b, "X": .x, "Y": .y, "L": .l, "R": .r,
            "Z": .z, "ZL": .zl, "Start": .start, "Home": .home, "Capture": .capture,
            "Dpad_Up": .up, "Dpad_Down": .down, "Dpad_Left": .left, "Dpad_Right": .right,
        ]
        func axis(_ value: Int) -> Double { min(1, max(-1, Double(value) / 1400)) }
        return GameCubeState(
            buttons: Set(state.buttons.compactMap { $0.value ? names[$0.key] : nil }),
            leftStick: Stick(x: axis(state.leftX), y: axis(state.leftY)),
            rightStick: Stick(x: axis(state.rightX), y: axis(state.rightY)),
            leftTrigger: Double(state.leftTrigger) / 255,
            rightTrigger: Double(state.rightTrigger) / 255,
            battery: state.battery.map {
                BatteryState(percentage: $0.percentage, isCharging: $0.isCharging,
                             hasExternalPower: $0.hasExternalPower)
            }, rawReport: data)
    }
}
