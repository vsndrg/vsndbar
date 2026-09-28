// The internal battery, read from IOKit's power sources: no polling, macOS
// notifies on every change (level, charging, time estimate, power source).

import Foundation
import IOKit.ps

struct BatteryState: Equatable {
  /// charge: 0 discharging, 1 charging, 2 on AC but not charging
  let level: Int, charge: Int, low: Bool
  /// the macOS battery menu's wording, e.g. "0:39 Until Full"
  let status: String
}

enum Battery {
  /// nil: no internal battery (desktop Macs): the island is dropped.
  static func read() -> BatteryState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for s in list {
      guard let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any],
            d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            d[kIOPSIsPresentKey] as? Bool ?? true else { continue }
      let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
      let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
      let level = max > 0 ? Int((Double(cur) * 100 / Double(max)).rounded()) : cur
      let ac = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
      let charging = d[kIOPSIsChargingKey] as? Bool ?? false
      let charge = charging ? 1 : (ac ? 2 : 0)
      let minutes = d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
      let remaining = minutes > 0 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : nil
      return BatteryState(level: level, charge: charge, low: level <= Config.batteryLow && !ac,
                          status: statusText(level: level, charge: charge, remaining: remaining))
    }
    return nil
  }

  /// Wording and title case as in the macOS battery menu.
  static func statusText(level: Int, charge: Int, remaining: String?) -> String {
    switch charge {
    case 1: remaining.map { "\($0) Until Full" } ?? "Charging"
    case 2: level >= 100 ? "Fully Charged" : "Not Charging"
    default: remaining.map { "\($0) Remaining" } ?? "Calculating Time Remaining…"
    }
  }

  private static var source: CFRunLoopSource?

  /// Calls `changed` on the main run loop whenever a power source changes.
  static func watch(_ changed: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Callback(changed)).toOpaque()
    guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
      ctx.map { Unmanaged<Callback>.fromOpaque($0).takeUnretainedValue().fn() }
    }, box)?.takeRetainedValue() else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes) // also while a menu tracks (the battery menu)
    source = src
  }

  private final class Callback {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
  }
}
