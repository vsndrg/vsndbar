// Frame probe: every animated lens frame's time (mach ticks) → dumped on SIGUSR1.
import Foundation
enum Probe {
  static var times = [UInt64](repeating: 0, count: 200_000)
  static var n = 0
  static var keys = [Int](repeating: 0, count: 200_000)
  static var los = [Double](repeating: 0, count: 200_000)
  static var last: [Int: (CGFloat, CGFloat)] = [:]
  static var src: DispatchSourceSignal?
  static let path = ProcessInfo.processInfo.environment["PROBE_OUT"]
  /// key: which display's lens (its row width)
  static func frame(_ lo: CGFloat, _ hi: CGFloat, key: CGFloat) {
    let k = key.isFinite ? Int(key) : -1
    guard path != nil, last[k].map({ $0 != (lo, hi) }) ?? true else { return }
    last[k] = (lo, hi)
    if n < times.count { times[n] = mach_absolute_time(); keys[n] = k; los[n] = Double(lo); n += 1 }
  }
  /// an event (key: -2 state applied)
  static func mark(_ key: Int) {
    guard path != nil, n < times.count else { return }
    times[n] = mach_absolute_time(); keys[n] = key; los[n] = 0; n += 1
  }
  static func start() {
    guard let path else { return }
    signal(SIGUSR1, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    s.setEventHandler {
      let text = (0..<n).map { "\(times[$0]) \(keys[$0]) \(los[$0])" }.joined(separator: "\n")
      try? text.write(toFile: path, atomically: true, encoding: .utf8)
      n = 0
    }
    s.resume()
    src = s
    // main run loop: -3 woke up, -4 goes to sleep
    let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, a in
      mark(a == .afterWaiting ? -3 : -4)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
  }
}
