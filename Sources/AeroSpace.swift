// AeroSpace, over its sockets (no CLI process per event or click):
// - state: the patched server (aerospace patches/bar-state.patch) pushes every
//   workspace with its monitor, visibility and apps as one JSON line per
//   change; the current state comes right after connecting.
// - commands: the server's own socket, the protocol the `aerospace` CLI speaks.

import AppKit

struct AeroWorkspace: Decodable, Equatable {
  let name: String
  /// NSScreen index, 1-based
  let monitor: Int
  let visible: Bool
  /// bundle ids, once each, ordered like `list-windows` (by app name)
  let apps: [String]
}

struct AeroState: Decodable, Equatable {
  let focused: String
  let workspaces: [AeroWorkspace]
}

final class AeroSpace {
  var onState: ((AeroState) -> Void)?
  private var fd: Int32 = -1
  private var source: DispatchSourceRead?
  private var buffer = Data()
  private var chunk = [UInt8](repeating: 0, count: 65536)
  private var retry: DispatchWorkItem?

  func start() {
    // AeroSpace (re)started: its socket shows up a moment after launch
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
    ) { [weak self] n in
      let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      if app?.bundleIdentifier == Config.aerospaceApp { self?.connect(attempt: 0) }
    }
    connect(attempt: 0)
  }

  /// Retries for ~10s (AeroSpace starting up); after that only its next launch
  /// reconnects.
  private func connect(attempt: Int) {
    guard fd < 0 else { return }
    retry?.cancel()
    retry = nil
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { return }
    if unixConnect(s, Config.aerospaceBarSocket) {
      fd = s
      let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
      src.setEventHandler { [weak self] in self?.readAvailable() }
      src.setCancelHandler { close(s) }
      src.resume()
      source = src
      return
    }
    close(s)
    guard attempt < 40 else { return }
    let w = DispatchWorkItem { [weak self] in self?.connect(attempt: attempt + 1) }
    retry = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
  }

  private func readAvailable() {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 {
      if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
      // AeroSpace quit: wait for its next launch
      source?.cancel()
      source = nil
      fd = -1
      buffer.removeAll()
      return
    }
    buffer.append(contentsOf: chunk[0..<n])
    // only the newest complete line matters
    guard let end = buffer.lastIndex(of: 0x0A) else { return }
    let lines = buffer[buffer.startIndex..<end]
    let start = lines.lastIndex(of: 0x0A).map { lines.index(after: $0) } ?? lines.startIndex
    let line = Data(buffer[start..<end])
    buffer.removeSubrange(buffer.startIndex...end)
    if let state = try? JSONDecoder().decode(AeroState.self, from: line) { onState?(state) }
  }

  /// Runs an AeroSpace command (like `aerospace workspace 3`) without waiting
  /// for its answer.
  static func run(_ args: [String]) {
    DispatchQueue.global(qos: .userInteractive).async {
      let s = socket(AF_UNIX, SOCK_STREAM, 0)
      guard s >= 0 else { return }
      defer { close(s) }
      var one: Int32 = 1
      setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      guard unixConnect(s, Config.aerospaceSocket) else { return }
      let request: [String: Any] = ["args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull()]
      guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
      _ = data.withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
      // the answer comes once the command has run
      var answer = [UInt8](repeating: 0, count: 4096)
      _ = read(s, &answer, answer.count)
    }
  }
}

func unixConnect(_ fd: Int32, _ path: String) -> Bool {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
  withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
  return withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
  }
}
