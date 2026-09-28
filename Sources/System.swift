// macOS facts the bar reads: displays, keyboard layout, app icons, fonts, and
// the battery glyph.

import AppKit
import Carbon
import SwiftUI

// MARK: - Drawing

/// Apple's continuous corner curve, exactly as the system draws it.
func squircle(_ rect: CGRect, _ r: CGFloat) -> CGPath {
  RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect).cgPath
}

private var fontCache: [String: NSFont] = [:]
func nsFont(_ family: String, _ style: String, _ size: CGFloat) -> NSFont {
  let key = "\(family)|\(style)|\(size)"
  if let f = fontCache[key] { return f }
  let d = NSFontDescriptor(fontAttributes: [.family: family, .face: style])
  let f = NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
  fontCache[key] = f
  return f
}

/// Battery: a solid squircle body, all of it opaque (legible on the clear
/// glass; the level reads from the number), the level knocked out of it;
/// optional bolt to the left.
let batteryHeight: CGFloat = 13
func batteryWidth(_ state: Int) -> CGFloat { (state > 0 ? 9 : 0) + 28 + 1 + 2 }

func drawBattery(_ ctx: CGContext, at origin: CGPoint, level: Int, state: Int, color: CGColor,
                 style: String = "Bold", size: CGFloat = 10) {
  let bw: CGFloat = 28, bh = batteryHeight, nub: CGFloat = 2, gap: CGFloat = 1
  ctx.saveGState()
  ctx.translateBy(x: origin.x, y: origin.y)
  ctx.beginTransparencyLayer(auxiliaryInfo: nil) // keeps the digit knock-out local
  if state > 0 {
    let b = CGMutablePath(), cy = bh / 2, cx: CGFloat = 3.5
    b.move(to: CGPoint(x: cx + 1.2, y: cy + 5.6))
    b.addLine(to: CGPoint(x: cx - 3.2, y: cy - 0.8))
    b.addLine(to: CGPoint(x: cx - 0.2, y: cy - 0.8))
    b.addLine(to: CGPoint(x: cx - 1.2, y: cy - 5.6))
    b.addLine(to: CGPoint(x: cx + 3.2, y: cy + 0.8))
    b.addLine(to: CGPoint(x: cx + 0.2, y: cy + 0.8))
    b.closeSubpath()
    ctx.addPath(b); ctx.setFillColor(color); ctx.fillPath()
    ctx.translateBy(x: 9, y: 0)
  }
  let body = CGRect(x: 0, y: 0, width: bw, height: bh)
  ctx.setFillColor(color)
  ctx.addPath(squircle(body, 4)); ctx.fillPath()
  ctx.addPath(squircle(CGRect(x: bw + gap, y: bh / 2 - 2.25, width: nub, height: 4.5), 1)); ctx.fillPath()

  let f = nsFont(Config.family, style, size)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(level)", attributes: [
    .font: f, .foregroundColor: NSColor(cgColor: color)!, .kern: -0.2,
  ]))
  let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  let pos = CGPoint(x: (bw - tw) / 2, y: (bh - f.capHeight) / 2)
  ctx.setBlendMode(.destinationOut)
  ctx.textPosition = pos; CTLineDraw(line, ctx)
  ctx.endTransparencyLayer()
  ctx.restoreGState()
}

var iconCache: [String: NSImage] = [:]
func appIcon(_ bundle: String) -> NSImage {
  if let i = iconCache[bundle] { return i }
  let ws = NSWorkspace.shared
  let img = ws.urlForApplication(withBundleIdentifier: bundle).map { ws.icon(forFile: $0.path) }
    ?? ws.icon(for: .applicationBundle)
  iconCache[bundle] = img
  return img
}

// MARK: - Displays

func displayID(_ s: NSScreen) -> CGDirectDisplayID {
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func screen(_ did: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { displayID($0) == did } }

/// What kind of device a display is: builtin, ipad (Sidecar reports vendor
/// 'aapl' and model 'iPad' as FourCCs) or display. Names are localized, so
/// they aren't used.
func displayKind(_ id: CGDirectDisplayID) -> String {
  if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
  if CGDisplayVendorNumber(id) == 0x6161_706C && CGDisplayModelNumber(id) == 0x6950_6164 { return "ipad" }
  return "display"
}

/// SF Symbol of each display kind: workspaces living on another display carry it.
func deviceSymbol(_ kind: String) -> String {
  switch kind {
  case "builtin": "laptopcomputer"
  case "ipad": "ipad.landscape"
  default: "display"
  }
}

/// cmd-shift-b swaps the bar and the system menu bar. The menu bar stays
/// auto-hidden: turning that off changes every display's usable area, and
/// WindowServer then pulls the windows AeroSpace parks in a corner back into
/// view (~100ms, until AeroSpace re-hides them). SkyLight's per-display
/// override just shows it. The override outlives the process: the daemon
/// clears it at start.
private typealias MenuBarOverride = @convention(c) (Int32, UInt32, Bool) -> Int32
private let menuBarOverride: MenuBarOverride? = {
  guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
        let f = dlsym(h, "SLSSetMenuBarVisibilityOverrideOnDisplay") else { return nil }
  return unsafeBitCast(f, to: MenuBarOverride.self)
}()
/// displays the override shows the menu bar on (setting it again is a screen
/// change again: only new displays get it)
private var menuBarShownOn = Set<CGDirectDisplayID>()

func showMenuBar(_ on: Bool, force: Bool = false) {
  guard let f = menuBarOverride else { return }
  let cid = CGSMainConnectionID()
  for s in NSScreen.screens {
    let did = displayID(s)
    guard force || menuBarShownOn.contains(did) != on else { continue }
    _ = f(cid, did, on)
    if on { menuBarShownOn.insert(did) } else { menuBarShownOn.remove(did) }
  }
}

/// Menu bar height of each display (0 = unknown). WindowServer keeps one
/// menu bar window per display, listed even while the menu bar is
/// auto-hidden (then just moved above the screen). Matched by owner and
/// level: window names of other apps need Screen Recording.
func menuBarHeights() -> [CGDirectDisplayID: Int] {
  var out: [CGDirectDisplayID: Int] = [:]
  let level = Int(CGWindowLevelForKey(.mainMenuWindow))
  let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  let bars = list.compactMap { w -> CGRect? in
    guard w[kCGWindowOwnerName as String] as? String == "Window Server",
          w[kCGWindowLayer as String] as? Int == level,
          let d = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: d)
  }
  for s in NSScreen.screens {
    let id = displayID(s), b = CGDisplayBounds(id)
    if let r = bars.first(where: { abs($0.minX - b.minX) < 1 && abs($0.width - b.width) < 1 }) {
      out[id] = Int(r.height)
    }
  }
  return out
}

/// A connected display. `mon` is its NSScreen index, 1-based: AeroSpace's
/// monitor-appkit-nsscreen-screens-id.
struct Display: Equatable {
  let mon: Int
  let did: CGDirectDisplayID
  let kind: String
  /// menu bar height, 0 = unknown (a new display gets its menu bar a bit later)
  let menuBar: Int
  var strip: CGFloat { Config.strip(menuBar: menuBar) }
}

func currentDisplays() -> [Display] {
  let menuBars = menuBarHeights()
  return NSScreen.screens.enumerated().map { i, s in
    let did = displayID(s)
    return Display(mon: i + 1, did: did, kind: displayKind(did), menuBar: menuBars[did] ?? 0)
  }
}

// Private (SkyLight via CoreGraphics): the Spaces of every display, as the
// Mission Control / AeroSpace see them.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

/// Whether the display currently shows a native fullscreen app's Space.
func showsFullscreenSpace(_ id: CGDirectDisplayID) -> Bool {
  guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
        let str = CFUUIDCreateString(nil, uuid) as String?,
        let list = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return false }
  let entry = list.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(str) == .orderedSame }
    // with "Displays have separate Spaces" off there is one entry for all displays
    ?? (list.count == 1 ? list.first : nil)
  let current = entry?["Current Space"] as? [String: Any]
  return (current?["type"] as? Int) == 4
}

// MARK: - Keyboard layout

func layoutCode() -> String {
  let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
  if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
    let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] ?? []
    if let l = langs.first { return String(l.prefix(2)).uppercased() }
  }
  return "??"
}

func sourceID(_ s: TISInputSource) -> String {
  guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
  return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func nextLayout() {
  let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
  guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
        !list.isEmpty else { return }
  let cur = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
  let i = list.firstIndex { sourceID($0) == cur } ?? -1
  TISSelectInputSource(list[(i + 1) % list.count])
}

// MARK: - Icon theme

/// System Settings → Appearance → Icons (default / dark / clear / tinted) only
/// changes global preferences; AppKit's own notification doesn't reach other
/// processes. The bar's app icons are cached: they are re-read on a change.
func iconTheme() -> String {
  let keys = ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor"]
  return keys.map { k in
    CFPreferencesCopyAppValue(k as CFString, kCFPreferencesAnyApplication).map { "\($0)" } ?? "-"
  }.joined(separator: "|").filter { $0.isLetter || $0.isNumber || $0 == "|" || $0 == "." || $0 == "-" }
}

// MARK: - Backdrop

/// CGWindowListCreateImage is gone from the SDK (macOS 15) but still in the
/// system. Below the bar's window lies only the desktop (the wallpaper and the
/// desktop icons: windows sit above the backstop menu level) — what the glass
/// refracts. No screen recording permission needed for that.
private typealias WindowListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
private let windowListImage: WindowListImage? = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
  .map { unsafeBitCast($0, to: WindowListImage.self) }

private let linear: [Float] = (0..<256).map { i in
  let c = Float(i) / 255
  return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

/// Relative luminance (0 black … 1 white) of what lies below `window` in the
/// top `height` points of display `did`: one value per point column.
func backdropProfile(_ did: CGDirectDisplayID, below window: CGWindowID, height: CGFloat) -> [Float]? {
  let b = CGDisplayBounds(did)
  guard let f = windowListImage, b.width > 0, height > 0,
        let img = f(CGRect(x: b.minX, y: b.minY, width: b.width, height: height),
                    CGWindowListOption.optionOnScreenBelowWindow.rawValue, window,
                    CGWindowImageOption([.boundsIgnoreFraming, .nominalResolution]).rawValue)?.takeRetainedValue()
  else { return nil }
  let w = Int(b.width), h = max(1, Int(height))
  var px = [UInt8](repeating: 0, count: w * h * 4)
  let ok = px.withUnsafeMutableBytes { buf -> Bool in
    guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard ok else { return nil }
  var out = [Float](repeating: 0, count: w)
  for y in 0..<h {
    for x in 0..<w {
      let i = (y * w + x) * 4
      out[x] += 0.2126 * linear[Int(px[i])] + 0.7152 * linear[Int(px[i + 1])] + 0.0722 * linear[Int(px[i + 2])]
    }
  }
  return out.map { $0 / Float(h) }
}

/// The wallpaper store (Index.plist) without its LastUse stamps: what is
/// chosen for which display and Space.
func wallpaperChoice() -> NSDictionary? {
  let path = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
  guard let d = FileManager.default.contents(atPath: path),
        let p = try? PropertyListSerialization.propertyList(from: d, format: nil) else { return nil }
  func strip(_ v: Any) -> Any {
    if let dict = v as? [String: Any] {
      return dict.filter { $0.key != "LastUse" }.mapValues(strip)
    }
    if let arr = v as? [Any] { return arr.map(strip) }
    return v
  }
  return strip(p) as? NSDictionary
}
