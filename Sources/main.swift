// VsndBar — the glass bar (and a few system chores) in one process.
//
//   vsndbar launch     what the LaunchAgent runs: opens the app as `daemon` through LaunchServices
//                      and lives as long as it does (KeepAlive restarts both)
//   vsndbar daemon     the bar: Liquid Glass windows over the notch strip of every display,
//                      workspaces from AeroSpace, layout │ battery │ clock; masks the built-in
//                      display's bottom corners; reconnects Sidecar after wake
//   vsndbar toggle     the bar ⇄ the system menu bar (cmd-shift-b in aerospace.toml)
//   vsndbar layout [next]   print / switch keyboard layout
//   vsndbar screens    per display: "<NSScreen index, 1-based> <CGDirectDisplayID> <menu bar height> <kind>"
//   vsndbar sleep      end Sidecar sessions, then sleep the system (F6 in Karabiner;
//                      the daemon reconnects the iPad after wake)

import AppKit
import notify

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "launch":
  launch()
case "daemon":
  Daemon().run()
case "toggle":
  notify_post(Config.toggleNotification)
case "layout":
  if args.count > 1, args[1] == "next" { nextLayout() } else { print(layoutCode()) }
case "screens":
  for d in currentDisplays() { print(d.mon, d.did, d.menuBar, d.kind) }
case "sleep":
  SidecarSleep().run()
default:
  FileHandle.standardError.write("usage: vsndbar launch|daemon|toggle|layout [next]|screens|sleep\n".data(using: .utf8)!)
  exit(1)
}

/// Only an app LaunchServices launched gets an app's main thread priority (46;
/// 31 when exec'd by launchd), and the bar renders every animation frame there.
func launch() -> Never {
  let cfg = NSWorkspace.OpenConfiguration()
  cfg.arguments = ["daemon"]
  cfg.activates = false
  cfg.addsToRecentItems = false
  NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { app, error in
    guard let app else {
      FileHandle.standardError.write("vsndbar launch: \(error?.localizedDescription ?? "failed")\n".data(using: .utf8)!)
      exit(1)
    }
    let src = DispatchSource.makeProcessSource(identifier: app.processIdentifier, eventMask: .exit, queue: .main)
    src.setEventHandler { exit(0) }
    src.resume()
    watch = src
    if app.isTerminated { exit(0) }
  }
  dispatchMain()
}
nonisolated(unsafe) var watch: DispatchSourceProcess?
