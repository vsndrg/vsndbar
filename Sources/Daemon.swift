// The daemon: keeps the bar's state and hands it to the windows (Bar.swift).
//
// Left: every existing workspace (occupied, or shown on some display) on every
// display's bar. Workspaces live on monitors (the AeroSpace default). On each
// display's bar the workspace it shows gets the lens (clear glass on the
// focused display, a subdued one on the others); workspaces living on another
// display carry that display's device glyph (laptop, iPad, monitor) after the
// digit — so any workspace can be found from any bar, and it's clear where a
// click leads.
// Right, the same on every display: keyboard layout │ battery │ clock.

import AppKit
import Carbon
import notify

// MARK: - State

/// Geometry and type, in the bar's units (Config); scaled per display.
struct BarStyle: Equatable {
  var gap = Config.gap, bar = Config.bar
  var pillH = Config.pill, inset = Config.inset
  /// Corner radius of the islands and the tooltip (the menu slider, 0...cornerMax); each
  /// shape takes min(corner, its height / 2), inner pills concentric
  var corner = Config.cornerDefault, cornerMax = Config.cornerMax
  var family = Config.family, size = Config.textSize, battery = Config.batteryText
  var primary = Config.weightDefault, secondary = Config.lighter[Config.weightDefault]!
  /// popupR: the menu's (system)
  var popupH = Config.popupHeight, popupR = Config.popupRadius, popupOffset = Config.popupOffset
  var weights = Config.weights

  var island: CGFloat { bar - gap }
  var radius: CGFloat { min(corner, island / 2) }
  var pillR: CGFloat { max(0, radius - inset) }
}

struct SpaceItem: Equatable, Identifiable {
  let n: Int
  let apps: [String]
  let shown: Bool      // this display shows it: the lens
  let device: String?  // lives on another display: that display's SF Symbol
  var id: Int { n }
}

struct DisplayState: Equatable {
  let did: CGDirectDisplayID
  let strip: CGFloat   // min(bar, the display's menu bar height)
  let focused: Bool    // the focused display: a clear lens, else a subdued one
  let spaces: [SpaceItem]
}

struct StatusState: Equatable {
  var input = "EN", date = "", time = ""
  var battery: BatteryState?
}

struct BarState: Equatable {
  var hidden = false // cmd-shift-b
  var style = BarStyle()
  var displays: [DisplayState] = []
  var status = StatusState()
}

// MARK: - Theme

/// Text weight and corner radius, picked in the right-click menu, kept in
/// ~/.local/state/vsndbar/theme ("weight=Medium\ncorner=8.5").
struct Theme {
  var weight = Config.weightDefault
  var corner = Config.cornerDefault

  static let path = Config.state + "/theme"

  static func load() -> Theme {
    var t = Theme()
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
      try? fm.createDirectory(atPath: Config.state, withIntermediateDirectories: true)
      try? fm.copyItem(atPath: Config.legacyState + "/theme", toPath: path)
    }
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
      guard kv.count == 2 else { continue }
      if kv[0] == "weight", Config.lighter[kv[1]] != nil { t.weight = kv[1] }
      if kv[0] == "corner", let v = Double(kv[1]) { t.corner = max(0, min(CGFloat(v), Config.cornerMax)) }
    }
    return t
  }

  func save() {
    try? FileManager.default.createDirectory(atPath: Config.state, withIntermediateDirectories: true)
    try? "weight=\(weight)\ncorner=\(corner.clean)\n".write(toFile: Theme.path, atomically: true, encoding: .utf8)
  }

  func apply(to s: inout BarStyle) {
    s.primary = weight
    s.secondary = Config.lighter[weight] ?? weight
    s.corner = corner
  }
}

extension CGFloat {
  /// 8.5 → "8.5", 10 → "10"
  var clean: String { self == rounded() ? String(Int(self)) : "\(Double(self))" }
}

// MARK: - Daemon

/// Where new workspaces open: the main monitor (NSScreen index 1).
let mainMonitor = 1

final class Daemon {
  let bar = GlassBar()
  let corners = Corners(radius: Config.screenCorner)
  let sidecar = SidecarReconnect()
  let aerospace = AeroSpace()

  var theme = Theme.load()
  var hidden = false
  var aero: AeroState?
  var displays = currentDisplays()
  var status = StatusState()

  var minuteTimer: Timer?
  var prefsWatcher: DispatchSourceFileSystemObject?
  var iconThemeNow = iconTheme()
  var toggleToken: Int32 = 0
  var displaySettle: DispatchWorkItem?
  var menuBarRetries = 0
  /// until AeroSpace's first state (or a timeout) the bar isn't shown: it
  /// appears with every island in place
  var ready = false

  static let dateFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE d MMM"
    return f
  }()
  static let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
  }()

  func run() {
    // launched through LaunchServices: stderr would go nowhere
    try? FileManager.default.createDirectory(atPath: Config.state, withIntermediateDirectories: true)
    freopen(Config.state + "/daemon.log", "a", stderr)
    NSApplication.shared.setActivationPolicy(.prohibited)

    bar.onMenuSelect = { [weak self] id in self?.menuSelect(id) }
    bar.onPreview = { [weak self] v in self?.bar.preview(corner: v) }

    // AeroSpace
    aerospace.onState = { [weak self] s in
      guard let self else { return }
      aero = s
      ready = true
      publish()
    }
    aerospace.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !ready else { return }
      ready = true // AeroSpace isn't there: show the rest
      publish()
    }

    // status
    status.input = layoutCode()
    status.battery = Battery.read()
    updateClock()
    Battery.watch { [weak self] in self?.batteryChanged() }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      status.input = layoutCode()
      publish()
    }
    scheduleMinute()
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      scheduleMinute()
      status.battery = Battery.read()
      updateClock()
    }
    for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        scheduleMinute()
        updateClock()
      }
    }

    // displays
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
    settleMenuBars()
    corners.update()
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.corners.refresh()
    }

    // cmd-shift-b: `vsndbar toggle`
    notify_register_dispatch(Config.toggleNotification, &toggleToken, .main) { [weak self] _ in
      guard let self else { return }
      hidden.toggle()
      publish()
    }

    sidecar.watch()
    watchIconTheme()
    NSApplication.shared.run()
  }

  /// The whole state, to every display's window (unchanged parts are skipped there).
  func publish() {
    guard ready else { return }
    var style = BarStyle()
    theme.apply(to: &style)
    bar.apply(BarState(hidden: hidden, style: style, displays: displayStates(), status: status))
  }

  // MARK: Workspaces

  func displayStates() -> [DisplayState] {
    var home: [Int: Int] = [:]    // workspace → monitor it lives on
    var apps: [Int: [String]] = [:]
    var shown: [Int: Int] = [:]   // monitor → workspace it shows
    var focusedMon = mainMonitor
    for w in aero?.workspaces ?? [] {
      if w.name == aero?.focused { focusedMon = w.monitor }
      guard let n = Int(w.name) else { continue }
      home[n] = w.monitor
      apps[n] = w.apps
      if w.visible { shown[w.monitor] = n }
    }
    // existing: occupied or shown somewhere, in numeric order
    let existing = Set(apps.filter { !$0.value.isEmpty }.keys).union(shown.values).sorted()
    let kinds = Dictionary(displays.map { ($0.mon, $0.kind) }) { a, _ in a }
    return displays.map { d in
      let spaces = existing.map { n in
        let mon = home[n] ?? mainMonitor
        let here = mon == d.mon
        return SpaceItem(n: n, apps: apps[n] ?? [], shown: here && shown[d.mon] == n,
                         device: here ? nil : deviceSymbol(kinds[mon] ?? "display"))
      }
      return DisplayState(did: d.did, strip: d.strip, focused: focusedMon == d.mon, spaces: spaces)
    }
  }

  // MARK: Displays

  /// Displays come and go (Sidecar): the windows are re-placed right away, the
  /// display list is re-read once the change settles (it arrives in bursts).
  func screensChanged() {
    corners.update()
    bar.screensChanged()
    displaySettle?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let list = currentDisplays()
      guard !list.isEmpty else { return } // mid-reconfiguration: keep what we have
      displays = list
      menuBarRetries = 0
      publish()
      settleMenuBars()
    }
    displaySettle = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
  }

  /// A newly connected display gets its menu bar window a bit later: re-read
  /// a few times until every menu bar height is known.
  func settleMenuBars() {
    guard displays.contains(where: { $0.menuBar == 0 }), menuBarRetries < 5 else { return }
    menuBarRetries += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      let list = currentDisplays()
      if !list.isEmpty && list != displays {
        displays = list
        publish()
      }
      settleMenuBars()
    }
  }

  // MARK: Status

  func batteryChanged() {
    let b = Battery.read()
    guard b != status.battery else { return }
    status.battery = b
    publish()
  }

  func updateClock() {
    let now = Date()
    status.date = Daemon.dateFormat.string(from: now)
    status.time = Daemon.timeFormat.string(from: now)
    publish()
  }

  /// The clock changes right on every minute boundary, one wakeup a minute.
  /// Timers don't follow the wall clock across sleep or a clock change, so
  /// those re-align it.
  func scheduleMinute() {
    minuteTimer?.invalidate()
    let now = Date().timeIntervalSince1970
    let next = (floor(now / 60) + 1) * 60
    // a hair past the boundary, so the new minute is what the clock reads
    let t = Timer(fire: Date(timeIntervalSince1970: next + 0.005), interval: 0, repeats: false) { [weak self] _ in
      self?.updateClock()
      self?.scheduleMinute()
    }
    t.tolerance = 0.005
    RunLoop.main.add(t, forMode: .common)
    minuteTimer = t
  }

  // MARK: Theme menu

  /// weight.<Weight> | corner.<radius> (the slider, on release)
  func menuSelect(_ id: String) {
    if id.hasPrefix("weight.") {
      let w = String(id.dropFirst(7))
      guard Config.lighter[w] != nil, w != theme.weight else { return }
      theme.weight = w
    } else if id.hasPrefix("corner."), let v = Double(id.dropFirst(7)) {
      let r = max(0, min(CGFloat(v), Config.cornerMax))
      guard r != theme.corner else { return }
      theme.corner = r
    } else {
      return
    }
    theme.save()
    publish()
  }

  // MARK: Icon theme

  // cfprefsd replaces .GlobalPreferences.plist (a directory write) within a
  // second or two of the change.
  func watchIconTheme() {
    let fd = open(NSHomeDirectory() + "/Library/Preferences", O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
    src.setEventHandler { [weak self] in
      guard let self else { return }
      let t = iconTheme()
      guard t != iconThemeNow else { return }
      iconThemeNow = t
      bar.iconsChanged()
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    prefsWatcher = src
  }
}
