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

/// Battery, drawn like macOS: a solid squircle body, the charged part opaque,
/// the rest translucent, the level knocked out of the whole body (readable
/// wherever the fill edge falls); optional bolt to the left.
let batteryHeight: CGFloat = 13
func batteryWidth(_ state: Int) -> CGFloat { (state > 0 ? 9 : 0) + 28 + 1 + 2 }

func drawBattery(_ ctx: CGContext, at origin: CGPoint, level: Int, state: Int, color: CGColor,
                 style: String = "Bold", size: CGFloat = 10) {
  let bw: CGFloat = 28, bh = batteryHeight, nub: CGFloat = 2, gap: CGFloat = 1
  let empty: CGFloat = 0.4 // alpha of the uncharged part and the nub
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
    ctx.setAlpha(state == 1 ? 1 : 0.45)
    ctx.addPath(b); ctx.setFillColor(color); ctx.fillPath()
    ctx.setAlpha(1)
    ctx.translateBy(x: 9, y: 0)
  }
  let body = CGRect(x: 0, y: 0, width: bw, height: bh)
  ctx.setFillColor(color)
  ctx.setAlpha(empty)
  ctx.addPath(squircle(body, 4)); ctx.fillPath()
  ctx.addPath(squircle(CGRect(x: bw + gap, y: bh / 2 - 2.25, width: nub, height: 4.5), 1)); ctx.fillPath()
  ctx.setAlpha(1)
  ctx.saveGState()
  ctx.clip(to: CGRect(x: 0, y: 0, width: bw * CGFloat(max(0, min(100, level))) / 100, height: bh))
  ctx.addPath(squircle(body, 4)); ctx.fillPath() // over the translucent body: no seam at the edge
  ctx.restoreGState()

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
