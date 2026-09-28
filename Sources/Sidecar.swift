// Sidecar across sleep: F6 ends the sessions before sleeping (`vsndbar sleep`),
// the daemon connects the iPads again after wake.

import AppKit
import IOKit.pwr_mgt

let sleepLog = NSHomeDirectory() + "/.local/state/vsndbar/sleep.log"

/// Appends (the daemon and F6 both write here); past 256 KB keeps the newest half.
func sleepLogLine(_ s: String, to log: String = sleepLog) {
  let fm = FileManager.default
  if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }
  guard let h = FileHandle(forUpdatingAtPath: log) else { return }
  defer { h.closeFile() }
  let size = h.seekToEndOfFile()
  if size > 256 << 10 {
    h.seek(toFileOffset: size / 2)
    var tail = h.readDataToEndOfFile()
    if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: nl)) }
    h.truncateFile(atOffset: 0)
    h.write(tail)
  }
  h.write("\(Date()) \(s)\n".data(using: .utf8)!)
}

/// SidecarCore's display manager (private; what the Control Center display menu uses).
final class Sidecar {
  typealias Completion = @convention(block) (NSError?) -> Void
  typealias Call = @convention(c) (NSObject, Selector, NSObject, @escaping Completion) -> Void

  let manager: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
          let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
    return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
  }()

  func devices(_ key: String) -> [NSObject] { manager?.value(forKey: key) as? [NSObject] ?? [] }
  func id(_ d: NSObject) -> String { (d.value(forKey: "identifier") as? UUID)?.uuidString ?? "" }
  var connected: [NSObject] { devices("connectedDevices") }

  func call(_ name: String, _ device: NSObject, _ done: @escaping (NSError?) -> Void) {
    guard let m = manager else { return }
    let sel = NSSelectorFromString(name)
    let f = unsafeBitCast(m.method(for: sel), to: Call.self)
    f(m, sel, device) { e in DispatchQueue.main.async { done(e) } }
  }
}

/// Sidecar sessions end when the Mac sleeps (lid closed, idle, F6) and macOS
/// doesn't bring them back. Runs in the daemon: remembers the iPads connected
/// going to sleep and connects them again after wake, once the screen is
/// unlocked (the lock screen isn't worth mirroring). Closing the lid may drop
/// the iPad just before the sleep notification, so ones lost moments earlier
/// count too. The daemon may be restarted around a sleep (a crash, an
/// install), so both the list and recent losses are kept in files and a fresh
/// daemon picks them up. Log: ~/.local/state/vsndbar/sleep.log.
final class SidecarReconnect {
  static let wantPath = NSHomeDirectory() + "/.local/state/vsndbar/sidecar-reconnect"
  static let lostPath = NSHomeDirectory() + "/.local/state/vsndbar/sidecar-lost"
  let sidecar = Sidecar()
  let started = DispatchTime.now()  // uptime: stands still while asleep
  var sawSleep = false
  var connected = Set<String>()
  var lost: [String: Date] = [:] {  // disconnected iPads → when
    didSet {
      guard lost != oldValue else { return }
      if lost.isEmpty { try? FileManager.default.removeItem(atPath: Self.lostPath) }
      else {
        let text = lost.map { "\($0.key) \($0.value.timeIntervalSince1970)" }.sorted().joined(separator: "\n")
        try? text.write(toFile: Self.lostPath, atomically: true, encoding: .utf8)
      }
    }
  }
  var want = Set<String>() {  // to connect after wake
    didSet {
      if want.isEmpty { try? FileManager.default.removeItem(atPath: Self.wantPath) }
      else { try? want.sorted().joined(separator: "\n").write(toFile: Self.wantPath, atomically: true, encoding: .utf8) }
    }
  }
  var running = false, attempts = 0
  var loop = 0  // a retry scheduled by an earlier loop stops when this changes
  var done: () -> Void = {}

  func track() {
    let now = Set(sidecar.connected.map(sidecar.id))
    for i in connected.subtracting(now) { lost[i] = Date() }
    for i in now { lost[i] = nil }
    connected = now
  }

  func watch() {
    // left by the daemon this one replaced
    let text = (try? String(contentsOfFile: Self.lostPath, encoding: .utf8)) ?? ""
    for l in text.split(separator: "\n") {
      let f = l.split(separator: " ")
      guard f.count == 2, let t = Double(f[1]) else { continue }
      let date = Date(timeIntervalSince1970: t)
      if Date().timeIntervalSince(date) < 30 { lost[String(f[0])] = date }
    }
    if lost.isEmpty { try? FileManager.default.removeItem(atPath: Self.lostPath) }  // stale
    track()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
      self.track()
      // SidecarCore may catch up with the display change a moment later
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.track() }
    }
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in self.willSleep() }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in self.woke() }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { _ in if !self.want.isEmpty && !self.running { sleepLogLine("unlocked"); self.start() } }
    // left by a daemon that went to sleep (a day old = something went wrong, drop it)
    let attrs = try? FileManager.default.attributesOfItem(atPath: Self.wantPath)
    if let date = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(date) < 86400,
       let text = try? String(contentsOfFile: Self.wantPath, encoding: .utf8) {
      want = Set(text.split(separator: "\n").map(String.init))
      sleepLogLine("daemon started, pending reconnect: \(want.sorted())")
      didWake()
    } else {
      want = []
    }
  }

  func willSleep() {
    sawSleep = true
    track()
    let recent = lost.filter { Date().timeIntervalSince($0.value) < 30 }.keys
    lost = [:]
    // never shrinks: a dark wake can sleep again with the iPad already gone
    want.formUnion(connected.union(recent))
    running = false  // a retry loop from the last wake stops
    if !want.isEmpty { sleepLogLine("will sleep, reconnect after wake: \(want.sorted())") }
  }

  /// Woken without a willSleep: this daemon started while the Mac was already
  /// going to sleep (it was restarted), so what it saw lost counts.
  func woke() {
    let awake = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
    if !sawSleep && awake < 30 {
      track()
      if !lost.isEmpty { sleepLogLine("started while going to sleep, reconnect: \(lost.keys.sorted())") }
      want.formUnion(lost.keys)
      lost = [:]
    }
    sawSleep = true
    didWake()
  }

  func didWake() {
    guard !want.isEmpty else { return }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    if session?["CGSSessionScreenIsLocked"] as? Bool == true { sleepLogLine("did wake, waiting for unlock"); return }
    sleepLogLine("did wake")
    start()
  }

  /// Once: unlock right after wake and didWake both get here.
  func start() {
    guard !running else { return }
    running = true
    attempts = 0
    loop += 1
    reconnect(loop)
  }

  func finish(_ s: String) {
    sleepLogLine(s)
    want = []
    running = false
    done()
  }

  /// The iPad may need a few seconds after wake to show up; retry for about a minute.
  func reconnect(_ loop: Int) {
    guard running, loop == self.loop else { return }
    let have = Set(sidecar.connected.map(sidecar.id))
    let missing = want.subtracting(have)
    if missing.isEmpty { return finish("all connected") }
    attempts += 1
    if attempts > 20 { return finish("giving up on \(missing.sorted())") }
    let available = sidecar.devices("devices")
    var left = missing.count
    for i in missing {
      let next = {
        left -= 1
        if left == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reconnect(loop) } }
      }
      guard let d = available.first(where: { self.sidecar.id($0) == i }) else { sleepLogLine("\(i) not available yet"); next(); continue }
      sidecar.call("connectToDevice:completion:", d) { e in
        sleepLogLine("connect \(i) \(e?.localizedDescription ?? "ok")")
        next()
      }
    }
  }
}

/// F6: a Sidecar session keeps the iPad lit while the Mac sleeps, so end it
/// first, then sleep. The daemon's SidecarReconnect brings the iPad back after
/// wake; this process only does that itself if the sleep doesn't happen.
/// It stays alive through the sleep and exits after wake: exiting inside the
/// willSleep handler leaves the sleep unacknowledged, and the kernel then
/// waits its full 30 s timeout with the screen off (the iPad gone for good by then).
final class SidecarSleep {
  let sidecar = Sidecar()
  var requested = false, asleep = false

  func run() {
    signal(SIGHUP, SIG_IGN)
    setsid()  // outlive the shell Karabiner runs us from
    let connected = sidecar.connected
    sleepLogLine("sidecar connected: \(connected.map(sidecar.id))")
    if connected.isEmpty { sleepNow(); exit(0) }

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { _ in self.asleep = true }  // returning acknowledges the sleep
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in if self.asleep { exit(0) } }

    var left = connected.count
    for d in connected {
      sidecar.call("disconnectFromDevice:completion:", d) { e in
        sleepLogLine("disconnected \(self.sidecar.id(d)) \(e?.localizedDescription ?? "ok")")
        left -= 1
        if left == 0 { self.sleepNow() }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.sleepNow() }  // Sidecar didn't answer
    // sleep refused (no willSleep) → give the iPad back right away
    // (uptime: after a sleep this fires 18 s into the wake)
    DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
      if self.asleep { exit(0) }
      sleepLogLine("sleep didn't happen")
      let r = SidecarReconnect()
      r.want = Set(connected.map(self.sidecar.id))
      r.done = { exit(0) }
      r.start()
    }
    RunLoop.main.run()
  }

  func sleepNow() {
    guard !requested else { return }
    requested = true
    sleepLogLine("sleep")
    let pm = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    IOPMSleepSystem(pm)
    IOServiceClose(pm)
  }
}

