// The two network islands.
//
// Geo: where the internet sees this Mac (through a VPN: its exit) — the
// public IP's country (a flag) and city, looked up over HTTPS
// (Config.geoServices, the first that answers) only when the network
// changes: NWPathMonitor reports interfaces coming and going (Wi‑Fi, cable,
// a VPN's utun), no polling.
// Link: the connection itself, an icon like the system's Wi‑Fi menu extra
// (arcs lit by the signal: CoreWLAN reports link quality changes), the
// details (network name, local IP, signal…) read when its menu
// opens. CoreWLAN gives the network's name only to an app allowed Location
// Services.

import AppKit
import CoreLocation
import CoreWLAN
import Network

struct GeoState: Equatable {
  /// loading: the network changed, the lookup is on its way; failed: online,
  /// but no service answered (after Config.geoRetries); offline: the island is gone
  enum Phase { case loading, offline, failed, ok }
  var phase = Phase.loading
  /// phase ok
  var ip = "", city = "", country = "", provider = ""

  /// the country code's regional indicators: "NL" → 🇳🇱
  var flag: String {
    String(String.UnicodeScalarView(country.uppercased().unicodeScalars.compactMap {
      Unicode.Scalar(0x1F1E6 - 0x41 + $0.value)
    }))
  }
  var countryName: String { Locale(identifier: "en_US").localizedString(forRegionCode: country) ?? country }
  /// the island's text: the city, or the country when the city isn't known
  var place: String { city.isEmpty ? countryName : city }

  var menu: MenuInfo {
    switch phase {
    case .ok:
      MenuInfo(header: city.isEmpty ? countryName : "\(city), \(countryName)",
               lines: ["IP Address: \(ip)"] + (provider.isEmpty ? [] : ["Provider: \(provider)"]),
               copy: [("Copy IP Address", ip)])
    case .loading: MenuInfo(header: "Looking Up Location…")
    case .failed: MenuInfo(header: "Location Unavailable")
    case .offline: MenuInfo(header: "Not Connected")
    }
  }
}

/// The link island's icon: an SF Symbol and, for Wi‑Fi, the share of its
/// arcs lit (SF Symbols' variable value).
struct LinkState: Equatable {
  var symbol = Config.linkWifiOff
  var level: Double?
}

/// What a network menu says (NetMenu): a header, grey lines, rows that copy
/// a value.
struct MenuInfo {
  var header: String
  var lines: [String] = []
  var copy: [(String, String)] = []
}

final class Net: NSObject, CWEventDelegate {
  var onGeo: ((GeoState) -> Void)?
  var onLink: ((LinkState) -> Void)?
  /// the signal changed (an open link menu reads the details again)
  var onQuality: (() -> Void)?
  private(set) var geo = GeoState()
  private(set) var link = LinkState()

  private let monitor = NWPathMonitor()
  private var path: NWPath?
  /// the last path's status, interfaces and addresses: a path update that
  /// changes none of them (they come often) isn't a new network
  private var signature = ""
  private var settle: DispatchWorkItem?
  /// bumped by every new network: older lookups' answers are dropped
  private var generation = 0
  private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = Config.geoTimeout
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c)
  }()
  private let location = CLLocationManager()
  private let wifi = CWWiFiClient.shared()

  func start() {
    if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    monitor.pathUpdateHandler = { [weak self] p in self?.pathChanged(p) }
    monitor.start(queue: .main)
    wifi.delegate = self
    for e in [CWEventType.powerDidChange, .linkDidChange, .ssidDidChange, .linkQualityDidChange] {
      try? wifi.startMonitoringEvent(with: e)
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                      queue: .main) { [weak self] _ in
      // the same network after sleep: only a failed lookup is tried again
      guard let self, geo.phase == .failed else { return }
      lookUp()
    }
  }

  // A network change arrives as a burst of path updates (a VPN going up
  // reports several): the lookup waits for it to settle.
  private func pathChanged(_ p: NWPath) {
    path = p
    updateLink()
    let sig = "\(p.status)|\(p.availableInterfaces.map(\.name))|\(addresses().sorted())"
    guard sig != signature else { return }
    signature = sig
    settle?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.lookUp() }
    settle = w
    DispatchQueue.main.asyncAfter(deadline: .now() + Config.geoSettle, execute: w)
  }

  // MARK: Geo

  private func lookUp() {
    generation += 1
    guard path?.status == .satisfied else { return setGeo(GeoState(phase: .offline)) }
    setGeo(GeoState(phase: .loading))
    attempt(generation, round: 0, service: 0)
  }

  /// Every service in turn; a round that fails is repeated after the next
  /// delay in Config.geoRetries, then the island gives up (until the network
  /// changes or the Mac wakes).
  private func attempt(_ gen: Int, round: Int, service: Int) {
    guard gen == generation else { return }
    guard service < Config.geoServices.count else {
      guard round < Config.geoRetries.count else { return setGeo(GeoState(phase: .failed)) }
      DispatchQueue.main.asyncAfter(deadline: .now() + Config.geoRetries[round]) { [weak self] in
        self?.attempt(gen, round: round + 1, service: 0)
      }
      return
    }
    let url = URL(string: Config.geoServices[service])!
    session.dataTask(with: url) { data, resp, _ in
      let ok = (resp as? HTTPURLResponse)?.statusCode == 200
      let found = ok ? data.flatMap(Net.parse) : nil
      DispatchQueue.main.async { [weak self] in
        guard let self, gen == generation else { return }
        guard let found else { return attempt(gen, round: round, service: service + 1) }
        var s = GeoState(phase: .ok)
        (s.ip, s.city, s.country, s.provider) = found
        setGeo(s)
      }
    }.resume()
  }

  /// The services' answers differ a little: ip.sb and geojs.io carry the
  /// provider as isp / organization_name, ipwho.is under connection.
  static func parse(_ d: Data) -> (String, String, String, String)? {
    guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          j["success"] as? Bool ?? true,
          let ip = j["ip"] as? String,
          let cc = j["country_code"] as? String, cc.count == 2 else { return nil }
    let provider = j["isp"] as? String ?? (j["connection"] as? [String: Any])?["isp"] as? String
      ?? j["organization_name"] as? String ?? ""
    return (ip, j["city"] as? String ?? "", cc, provider)
  }

  private func setGeo(_ s: GeoState) {
    guard s != geo else { return }
    geo = s
    onGeo?(s)
  }

  // MARK: Link

  /// The physical interface the path goes out through (not a VPN's tunnel).
  private var physical: NWInterface? {
    path?.availableInterfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
  }

  /// The icon like the system's: Wi‑Fi arcs by the signal; an iPhone's
  /// hotspot (Wi‑Fi or USB: an expensive path) its own; when offline, Wi‑Fi
  /// off, on but not joined (no arcs lit) or joined without internet.
  private func updateLink() {
    var s = LinkState()
    let w = wifi.interface()
    if let i = physical, path?.status == .satisfied {
      if path?.isExpensive == true || i.type == .cellular {
        s.symbol = Config.linkHotspot
      } else if i.type == .wifi {
        s.symbol = Config.linkWifi
        // the dot always, an arc more past each threshold, gone only
        // Config.wifiHysteresis below it (a signal hovering at a threshold
        // doesn't flicker); SF Symbols lights a layer of three past 0, ⅓, ⅔
        let rssi = w?.rssiValue() ?? 0, levels = [0.2, 0.5, 1]
        let up = Config.wifiArcs.filter { rssi >= $0 }.count
        let down = Config.wifiArcs.filter { rssi >= $0 - Config.wifiHysteresis }.count
        let now = link.symbol == Config.linkWifi ? levels.firstIndex(of: link.level ?? 0) ?? up : up
        s.level = levels[max(up, min(down, now))]
      } else {
        s.symbol = Config.linkEthernet
      }
    } else if w?.powerOn() != true {
      s.symbol = Config.linkWifiOff
    } else if w?.wlanChannel() != nil {
      s.symbol = Config.linkNoInternet
    } else {
      s.symbol = Config.linkWifi
      s.level = 0
    }
    guard s != link else { return }
    link = s
    onLink?(s)
  }

  /// The link menu, read now (Wi‑Fi details like the system menu's
  /// option-click ones).
  func linkMenu() -> MenuInfo {
    guard let i = physical else {
      let w = wifi.interface()
      return MenuInfo(header: w?.powerOn() == true ? "Wi‑Fi: Not Connected" : "Wi‑Fi: Off")
    }
    let local = address(i.name)
    var m = MenuInfo(header: path?.isExpensive == true ? "Personal Hotspot"
                     : i.type == .wifi ? "Wi‑Fi" : i.type == .cellular ? "Cellular" : "Ethernet")
    let w = i.type == .wifi ? wifi.interface(withName: i.name) : nil
    if let ssid = w?.ssid() { m.lines.append("Network: \(ssid)") }
    if let local { m.lines.append("IP Address: \(local)") }
    if let w, w.wlanChannel() != nil {
      m.lines.append("RSSI: \(w.rssiValue()) dBm")
      m.lines.append("Tx Rate: \(Int(w.transmitRate())) Mbps")
      if let c = w.wlanChannel() {
        let band = switch c.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: ""
        }
        let width = switch c.channelWidth {
        case .width20MHz: "20 MHz"
        case .width40MHz: "40 MHz"
        case .width80MHz: "80 MHz"
        case .width160MHz: "160 MHz"
        default: ""
        }
        let extra = [band, width].filter { !$0.isEmpty }.joined(separator: ", ")
        m.lines.append("Channel: \(c.channelNumber)" + (extra.isEmpty ? "" : " (\(extra))"))
      }
    }
    if path?.status != .satisfied { m.lines.append("No Internet Connection") }
    if let local { m.copy = [("Copy IP Address", local)] }
    return m
  }

  private func address(_ name: String) -> String? {
    addresses().first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
  }

  /// "en0=192.168.1.5" for every interface's IPv4 address but loopback's.
  private func addresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var out: [String] = []
    var p = head
    while let a = p?.pointee {
      defer { p = a.ifa_next }
      guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), a.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      out.append(String(cString: a.ifa_name) + "=" + String(cString: host))
    }
    return out
  }

  // CoreWLAN calls on its own queue.
  func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
  func linkDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
  func ssidDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
  func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
    wifiChanged()
  }

  private func wifiChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.updateLink()
      self?.onQuality?()
    }
  }
}
