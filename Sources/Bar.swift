// The bar itself: the daemon's own windows, one per display, drawn with
// SwiftUI's Liquid Glass (real NSGlassEffectView underneath — it refracts
// what is behind the window, so it can't be baked into an image).
//
// The daemon (Daemon.swift) hands over the whole state; a change lands in one
// SwiftUI transaction per window: islands, lens and text move together.
// Clicks, hover, the theme menu and the battery menu are handled here.

import AppKit
import SwiftUI

// MARK: - Model

/// One display's bar. Hit rects are kept out of @Published: they are reported
/// by the layout itself, and republishing them would re-render in a loop.
final class BarModel: ObservableObject {
  let did: CGDirectDisplayID
  @Published var style = BarStyle()
  @Published var display: DisplayState
  @Published var status = StatusState()
  @Published var hover: Int?
  /// bumped when app icons change (system icon theme)
  @Published var iconEpoch = 0
  /// false until the panel is first shown: the bar is laid out zero wide, then
  /// springs open (the islands fly in from the left edge)
  @Published var appeared = false
  var hits: [String: CGRect] = [:] // "ws.N" | "spaces" | "input" | "battery" | "clock", view points from the top-left
  let lens = Lens()
  /// What the glass lies on: luminance per point column (backdropProfile), nil = unknown.
  var backdrop: [Float]?
  /// Islands over a light backdrop, drawn in the light appearance (dark text),
  /// the others in the dark one — like the menu bar over the wallpaper.
  @Published var light: Set<String> = []

  init(_ d: DisplayState) {
    did = d.did
    display = d
  }

  /// The strip is the same islands scaled as a whole; gaps between islands stay `gap`.
  var scale: CGFloat { max(0.5, (display.strip - style.gap) / style.island) }
  var look: Look { Look(style: style, scale: scale) }

  static let islands = ["spaces", "input", "battery", "clock"]

  /// Each island's appearance from the mean luminance under it (the whole
  /// strip's until the layout reports where it is). Two thresholds: an island
  /// over a backdrop in between keeps what it has.
  func retone() {
    guard let p = backdrop, !p.isEmpty else { return }
    var next = Set<String>()
    for k in BarModel.islands {
      let r = hits[k] ?? CGRect(x: 0, y: 0, width: CGFloat(p.count), height: 0)
      let lo = max(0, min(p.count - 1, Int(r.minX))), hi = max(lo + 1, min(p.count, Int(r.maxX.rounded(.up))))
      let l = p[lo..<hi].reduce(0, +) / Float(hi - lo)
      if l > (light.contains(k) ? Config.lightOff : Config.lightOn) { next.insert(k) }
    }
    if next != light { withAnimation(Config.tone) { light = next } }
  }
}

extension View {
  /// The light or dark appearance for an island (BarModel.light): its glass
  /// and the label colors inside.
  func tone(_ light: Bool) -> some View { environment(\.colorScheme, light ? .light : .dark) }

  /// An island's content on a display without focus (Config.dimmed). Only the
  /// opacity animates on Config.focus: a switch moving focus and cells at once
  /// keeps its own animation for the cells.
  func dim(_ on: Bool) -> some View {
    animation(Config.focus) { $0.opacity(on ? Config.dimmed : 1) }
  }
}

/// What the islands are drawn with: the style at this display's scale. Views
/// take it (and their own data) by value, so SwiftUI skips the ones whose
/// inputs didn't change — a workspace switch doesn't redraw the clock.
struct Look: Equatable {
  let style: BarStyle
  let scale: CGFloat

  func font(_ primary: Bool, _ size: CGFloat? = nil) -> Font {
    Font(nsFont(style.family, primary ? style.primary : style.secondary, (size ?? style.size) * scale) as CTFont)
  }
}

/// The lens's edges in the row. Set in the same transaction as the state that
/// moves it when the cells stay put (a plain switch: it starts on the switch's
/// first frame); otherwise once the new layout reports where its cell is.
final class Lens: ObservableObject {
  @Published var lo: CGFloat = 0
  @Published var hi: CGFloat = 0
  var cells: [Int: CGRect] = [:] // workspace → its cell in the row, from the last layout

  /// Heads for workspace n's cell (animated by the caller's transaction).
  func target(_ n: Int?) {
    guard let n, let r = cells[n], r.minX != lo || r.maxX != hi else { return }
    lo = r.minX
    hi = r.maxX
  }

  /// After a layout: the first placement is instant, later ones spring.
  func follow(_ n: Int?) {
    guard let n, let r = cells[n] else { return }
    if lo == 0 && hi == 0 { lo = r.minX; hi = r.maxX; return }
    if r.minX != lo || r.maxX != hi { withAnimation(Config.lens) { lo = r.minX; hi = r.maxX } }
  }
}

struct HitKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  /// Reports this view's frame in the bar's coordinates under `key`.
  func hit(_ key: String) -> some View {
    background(GeometryReader { g in Color.clear.preference(key: HitKey.self, value: [key: g.frame(in: .named("bar"))]) })
  }
}

// MARK: - Views

struct SpaceCell: View, Equatable {
  let w: SpaceItem
  let look: Look
  /// bumped when app icons change (system icon theme)
  let iconEpoch: Int

  var body: some View {
    let s = look.scale
    let icon: CGFloat = (look.style.island - 8) * s, slot = icon + 2 * s
    let shown = Array(w.apps.prefix(w.apps.count > 8 ? 7 : 8))
    let overflow = w.apps.count - shown.count
    HStack(spacing: 0) {
      Text("\(w.n)").font(look.font(true))
        .foregroundStyle(w.shown ? .primary : .secondary)
      if let d = w.device {
        Image(systemName: d).font(.system(size: 12 * s, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 16 * s)
          .padding(.leading, 3 * s)
          .padding(.trailing, (w.apps.isEmpty ? 0 : 2) * s)
      }
      if !w.apps.isEmpty { Spacer().frame(width: 3 * s) }
      ForEach(shown, id: \.self) { a in
        Image(nsImage: appIcon(a)).resizable().interpolation(.high)
          .frame(width: icon, height: icon).frame(width: slot)
      }
      if overflow > 0 {
        Text("+\(overflow)").font(look.font(false, look.style.size - 1.5)).foregroundStyle(.secondary).frame(width: slot)
      }
    }
    .padding(.leading, 7 * s)
    // icons carry ~1.5pt of built-in margin, so 5 reads as 7
    .padding(.trailing, (w.apps.isEmpty ? 7 : 5) * s)
    .frame(height: look.style.pillH * s)
    .id("\(w.n).\(iconEpoch)")
  }
}

/// The lens: its edges animate on `Config.lens`, clamped to the
/// island so an overshoot squashes it against the edge instead of leaving it.
struct LensFrame: ViewModifier, Animatable {
  var lo: CGFloat, hi: CGFloat
  let maxX: CGFloat, height: CGFloat
  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { .init(lo, hi) }
    set { lo = newValue.first; hi = newValue.second }
  }
  func body(content: Content) -> some View {
    let l = max(0, min(lo, maxX)), r = max(l, min(hi, maxX))
    return content.frame(width: r - l, height: height).offset(x: l)
  }
}

struct CellKey: PreferenceKey {
  static var defaultValue: [Int: CGRect] = [:]
  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}
struct WidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The selection (Config.lensGlass), always interactive: see SpacesIsland.
let lensGlass = Config.lensGlass.interactive()
let lensGlassOther = Config.lensGlassOther.interactive()

struct SpacesIsland: View {
  @ObservedObject var m: BarModel
  @ObservedObject var lens: Lens
  @Namespace var ns
  @State var rowW: CGFloat = 0

  var lensTarget: Int? { m.display.spaces.first { $0.shown }?.n }

  var body: some View {
    let look = m.look, s = look.scale, st = look.style
    let pill = RoundedRectangle(cornerRadius: st.pillR * s, style: .continuous)
    HStack(spacing: st.inset * s) {
      ForEach(m.display.spaces) { w in
        SpaceCell(w: w, look: look, iconEpoch: m.iconEpoch).equatable()
          .background {
            if w.n == m.hover && !w.shown {
              pill.fill(.primary.opacity(0.5)).matchedGeometryEffect(id: "hover", in: ns)
            }
          }
          .background(GeometryReader { g in
            Color.clear.preference(key: CellKey.self, value: [w.n: g.frame(in: .named("row"))])
          })
          .hit("ws.\(w.n)")
          .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }
    }
    .dim(!m.display.focused)
    .coordinateSpace(name: "row")
    .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
    .onPreferenceChange(WidthKey.self) { rowW = $0 }
    .onPreferenceChange(CellKey.self) { c in
      lens.cells = c
      lens.follow(lensTarget)
    }
    .onChange(of: lensTarget) { lens.follow(lensTarget) }
    .background(alignment: .leading) {
      if lensTarget != nil {
        // Config.lensGlass on the focused display, lensGlassOther elsewhere. Interactive:
        // a plain glass effect re-animates from its old place once the frame
        // animation ends (the lens snapped back and ran again)
        Color.clear
          .glassEffect(m.display.focused ? lensGlass : lensGlassOther, in: pill)
          .modifier(LensFrame(lo: lens.lo, hi: lens.hi, maxX: rowW, height: st.pillH * s))
      }
    }
    .padding(st.inset * s)
    .frame(height: st.island * s)
    .glassEffect(Config.islandGlass, in: RoundedRectangle(cornerRadius: st.radius * s, style: .continuous))
    .hit("spaces")
    .tone(m.light.contains("spaces"))
  }
}

var batteryCache: [String: NSImage] = [:]
/// The battery glyph (System.swift drawBattery) as an image; a template
/// (tinted like the text) unless low (red).
func batteryImage(_ b: BatteryState, style: String, size: CGFloat, scale s: CGFloat) -> NSImage {
  let key = "\(b.level)|\(b.low)|\(style)|\(size)|\(s)"
  if let i = batteryCache[key] { return i }
  let img = NSImage(size: NSSize(width: batteryWidth * s, height: batteryHeight * s), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    ctx.scaleBy(x: s, y: s)
    let c = b.low ? NSColor.systemRed.cgColor : NSColor.black.cgColor
    drawBattery(ctx, level: b.level, color: c, style: style, size: size)
    return true
  }
  img.isTemplate = !b.low
  if batteryCache.count > 200 { batteryCache.removeAll() }
  batteryCache[key] = img
  return img
}

/// The charging bolt (System.swift drawBolt) as a template image.
func boltImage(scale s: CGFloat) -> NSImage {
  let key = "bolt|\(s)"
  if let i = batteryCache[key] { return i }
  let img = NSImage(size: NSSize(width: boltWidth * s, height: batteryHeight * s), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    ctx.scaleBy(x: s, y: s)
    drawBolt(ctx, color: NSColor.black.cgColor)
    return true
  }
  img.isTemplate = true
  batteryCache[key] = img
  return img
}

struct StatusIslands: View, Equatable {
  let status: StatusState
  let look: Look
  let light: Set<String>
  let dim: Bool

  func chip<C: View>(_ key: String, @ViewBuilder _ c: () -> C) -> some View {
    let s = look.scale
    return c()
      .dim(dim)
      .padding(.horizontal, 10 * s)
      .frame(height: look.style.island * s)
      .glassEffect(Config.islandGlass, in: RoundedRectangle(cornerRadius: look.style.radius * s, style: .continuous))
      .hit(key)
      .tone(light.contains(key))
  }

  var body: some View {
    let s = look.scale, st = look.style
    HStack(spacing: st.gap) {
      chip("input") {
        Text(status.input).font(look.font(true)).foregroundStyle(.primary)
          .frame(minWidth: 18 * s)
      }
      if let b = status.battery {
        chip("battery") {
          HStack(spacing: 2 * s) {
            if b.charge > 0 {
              Image(nsImage: boltImage(scale: s)).foregroundStyle(.primary)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            Image(nsImage: batteryImage(b, style: st.batteryWeight, size: st.battery, scale: s))
              .foregroundStyle(.primary)
          }
        }
      }
      chip("clock") {
        HStack(spacing: 6 * s) {
          Text(status.date).font(look.font(true)).foregroundStyle(.primary)
          Text(status.time).font(look.font(true)).monospacedDigit().foregroundStyle(.primary)
        }
      }
    }
  }
}

struct BarView: View {
  @ObservedObject var m: BarModel

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      SpacesIsland(m: m, lens: m.lens)
      Spacer(minLength: 0)
      StatusIslands(status: m.status, look: m.look, light: m.light, dim: !m.display.focused).equatable()
    }
    .padding(.horizontal, m.style.gap)
    .padding(.top, m.style.gap)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // the whole strip takes the mouse (a right click anywhere opens the menu, Config.themeMenu);
    // fully transparent pixels would let clicks through to the desktop
    .background(Color.black.opacity(0.002))
    .coordinateSpace(name: "bar")
    .onPreferenceChange(HitKey.self) {
      m.hits = $0
      m.retone()
    }
    .frame(width: m.appeared ? nil : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The strip's blur (Config.blurRadius), the content of its own window under
/// the bar's: WindowServer blurs what lies behind it, like Control Center's
/// backdrop and the soft scroll edge. Private Core Animation: a
/// CABackdropLayer with the variableBlur filter, its radius scaled by a mask
/// (full at the top, easing to zero at the bottom edge). If the classes are
/// ever gone the strip just stays clear.
final class BlurView: NSView {
  let backdrop: CALayer?
  let blur: NSObject?
  let saturate: NSObject?
  /// the saturation eases out with the radius: the whole effect fades to what is behind
  let fade = CALayer()
  var maskSize = CGSize.zero

  static var maxRadius: CGFloat { max(Config.blurRadius, Config.blurRadiusTop) }

  static func filter(_ type: String) -> NSObject? {
    (NSClassFromString("CAFilter") as? NSObject.Type)?
      .perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
  }

  init() {
    backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init()
    blur = BlurView.filter("variableBlur")
    saturate = Config.blurSaturation != 1 ? BlurView.filter("colorSaturate") : nil
    super.init(frame: .zero)
    wantsLayer = true
    guard let backdrop, let blur else { return }
    backdrop.setValue(true, forKey: "windowServerAware") // what is behind the window, not just in it
    blur.setValue(BlurView.maxRadius, forKey: "inputRadius") // the mask's 1
    blur.setValue(true, forKey: "inputNormalizeEdges")
    saturate?.setValue(Config.blurSaturation, forKey: "inputAmount")
    backdrop.filters = [blur] + (saturate.map { [$0] } ?? [])
    if saturate != nil { backdrop.mask = fade }
    layer?.addSublayer(backdrop)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    fit()
  }

  func fit() {
    guard let backdrop, let blur else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdrop.frame = bounds
    if bounds.size != maskSize {
      maskSize = bounds.size
      let h = bounds.height
      // the filter takes its mask in the layer's points, unstretched: full width
      blur.setValue(BlurView.mask(width: bounds.width, height: h) { BlurView.radius(at: $0, height: h) / BlurView.maxRadius },
                    forKey: "inputMaskImage")
      backdrop.filters = [blur] + (saturate.map { [$0] } ?? [])
      // a layer mask is stretched: one column
      fade.frame = bounds
      fade.contents = BlurView.mask(width: 1, height: h) { BlurView.fade(at: $0, height: h) }
    }
    CATransaction.commit()
  }

  /// 0 → 1 with every derivative 0 at both ends (C∞): where it meets a flat
  /// part nothing jumps, not the slope, not the curvature, nothing higher.
  static func smooth(_ x: CGFloat) -> CGFloat {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    let a = exp(-1 / x), b = exp(-1 / (1 - x))
    return a / (a + b)
  }

  /// Below the hold: the share of blurRadius, 1 at the hold's end, 0 at the
  /// bottom. A blur of a pixel or two shows only as lost fine contrast, which
  /// grows as the radius squared: the square goes down the C∞ step. (By
  /// ratio, like the rise, it spent half the fade on invisible radii and
  /// squeezed the visible 1 → 0.4 into a few points: read as an edge.)
  static func fade(at p: CGFloat, height h: CGFloat) -> CGFloat {
    let low = h - Config.blurBelow + min(Config.blurHold, Config.blurBelow)
    guard p > low else { return 1 }
    return sqrt(1 - smooth((p - low) / max(1, h - low))) // 0 at the hold's end, 1 at the bottom
  }

  /// The radius at a point row (from the top): blurRadius from blurRise below
  /// the screen's edge to blurHold below the strip; above, rising to
  /// blurRadiusTop at the edge; below, eased out (fade). The rise goes by
  /// ratio, not by points (a blur looks twice as strong at twice the radius:
  /// 1 → 3 over a few points read as a jump), along e^(1 - 1/u): leaves the
  /// flat part with every derivative 0.
  static func radius(at p: CGFloat, height h: CGFloat) -> CGFloat {
    let rise = max(1, min(Config.blurRise, h - Config.blurBelow))
    let (mid, top) = (Config.blurRadius, Config.blurRadiusTop)
    guard p < rise else { return mid * fade(at: p, height: h) }
    let u = (rise - p) / rise // 0 where the rise starts, 1 at the screen's edge
    let k = exp(1 - 1 / max(u, 0.001))
    return mid > 0 && top > 0 ? mid * pow(top / mid, k) : mid + (top - mid) * k
  }

  /// Alpha by point row (rows from the top, sampled at their middles).
  static func mask(width: CGFloat, height: CGFloat, _ value: (CGFloat) -> CGFloat) -> CGImage? {
    let w = max(1, Int(width.rounded(.up))), h = max(1, Int(height.rounded(.up)))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
      let v = UInt8((min(1, max(0, value(CGFloat(y) + 0.5))) * 255).rounded())
      for i in stride(from: y * w * 4, to: (y + 1) * w * 4, by: 1) { px[i] = v }
    }
    guard let data = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: data, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

// MARK: - Windows

/// Mouse handling for a daemon window: the daemon's app is never active, so
/// tracking must be activeAlways and the first click must count.
class TrackingHost<V: View>: NSHostingView<V> {
  var onMove: ((CGPoint?) -> Void)?
  var onClick: ((CGPoint, Bool) -> Void)? // point, right button

  required init(rootView: V) { super.init(rootView: rootView) }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }
  /// top-left origin, like the SwiftUI layout
  func point(_ e: NSEvent) -> CGPoint {
    let p = convert(e.locationInWindow, from: nil)
    return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
  }
  override func mouseMoved(with e: NSEvent) { onMove?(point(e)) }
  override func mouseEntered(with e: NSEvent) { onMove?(point(e)) }
  override func mouseExited(with e: NSEvent) { onMove?(nil) }
  override func mouseDown(with e: NSEvent) {} // the click is on up
  override func mouseUp(with e: NSEvent) { onClick?(point(e), false) }
  override func rightMouseDown(with e: NSEvent) { onClick?(point(e), true) }
}

/// Glass in a key window blurs harder and adds a brightening layer (the
/// "active" look); the daemon's windows never become key (that would take the
/// keyboard from the app in front), so they got the dull inactive look. No
/// public API covers this (Apple Developer Forums thread 818901, unanswered);
/// AppKit asks the window's private _hasActiveAppearance: say yes, like the
/// Dock. If it is ever renamed the bar just looks inactive again.
final class ActivePanel: NSPanel {
  @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
}

func barPanel(level: NSWindow.Level) -> NSPanel {
  let p = ActivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  p.isOpaque = false
  p.backgroundColor = .clear
  p.hasShadow = false
  p.hidesOnDeactivate = false
  p.acceptsMouseMovedEvents = true
  p.level = level
  p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
  return p
}

// MARK: - Popups

/// The theme menu: text weight, each in its own face (the selection is the
/// same lens as the workspaces', it slides to a new pick on the same spring;
/// hover slides too), and the corner radius slider. Stays open after a pick
/// (the new state re-renders it in place), closes on a click elsewhere.
final class MenuModel: ObservableObject {
  @Published var style = BarStyle()
  @Published var scale: CGFloat = 1
  @Published var hover: String?
  @Published var open = false // the glass is in (inserted / removed on Config.popup)
  var hits: [String: CGRect] = [:]
  /// the slider moved to a value / was released (GlassMenu)
  var slide: ((CGFloat) -> Void)?
  var slideEnded: (() -> Void)?
}

struct MenuView: View {
  @ObservedObject var m: MenuModel
  @Namespace var ns

  var pad: CGFloat { (m.style.popupH - 24) / 2 * m.scale }
  /// the system menu radius (not the slider's)
  var radius: CGFloat { m.style.popupR * m.scale }
  var pill: RoundedRectangle { RoundedRectangle(cornerRadius: max(0, radius - pad), style: .continuous) }

  /// live: false is the invisible copy that sizes the panel while the glass is out
  func row(_ kind: String, _ items: [String], _ selected: String, live: Bool,
           face: @escaping (String) -> String) -> some View {
    let s = m.scale, st = m.style, w = 84 * s, gap = 6 * s
    let i = items.firstIndex(of: selected)
    return HStack(spacing: gap) {
      ForEach(items, id: \.self) { item in
        let id = "\(kind).\(item)"
        Text(item).font(Font(nsFont(st.family, face(item), st.size * s) as CTFont))
          .foregroundStyle(.primary)
          .frame(width: w, height: 24 * s)
          .background {
            if live && id == m.hover && item != selected {
              pill.fill(.primary.opacity(0.5)).matchedGeometryEffect(id: "hover", in: ns)
            }
          }
          .hit(live ? id : "")
      }
    }
    .background(alignment: .leading) {
      // the bar's lens: interactive glass, its frame animated on Config.lens
      if live, let i {
        let lo = CGFloat(i) * (w + gap)
        Color.clear.glassEffect(lensGlass, in: pill)
          .modifier(LensFrame(lo: lo, hi: lo + w, maxX: .infinity, height: 24 * s))
          .animation(Config.lens, value: i)
      }
    }
  }

  /// The system slider, tracking the mouse itself (so it shows its own
  /// pressed glass knob); values go to GlassMenu. Its frame is the "corner" hit.
  func slider(live: Bool) -> some View {
    let s = m.scale, st = m.style
    let value = Binding(get: { Double(st.corner) }, set: { m.slide?(CGFloat($0)) })
    return HStack(spacing: 8 * s) {
      Image(systemName: "square").foregroundStyle(.primary)
      Slider(value: value, in: 0...Double(max(st.cornerMax, 1))) { if !$0 { m.slideEnded?() } }
        .tint(.primary)
        .hit(live ? "corner" : "")
      Image(systemName: "capsule").foregroundStyle(.primary)
    }
    .font(.system(size: st.size * s))
    .padding(.horizontal, 8 * s)
    .frame(width: (84 * 3 + 6 * 2) * s, height: 24 * s)
  }

  func rows(live: Bool) -> some View {
    let st = m.style
    return VStack(alignment: .leading, spacing: 6 * m.scale) {
      row("weight", st.weights, st.primary, live: live) { $0 }
      slider(live: live)
    }
    .padding(pad)
  }

  var body: some View {
    // Like the prototype: the menu is glass inserted into a container, so it
    // materializes (and dematerializes) the system way, not a window fade.
    ZStack {
      rows(live: false).hidden()
      GlassEffectContainer {
        if m.open {
          rows(live: true)
            .glassEffect(Config.popupGlass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEffectTransition(.materialize)
        }
      }
    }
    .padding(popupMargin)
    .coordinateSpace(name: "bar")
    .onPreferenceChange(HitKey.self) { m.hits = $0.filter { !$0.key.isEmpty } }
  }
}

/// Transparent room around a popup: (de)materializing glass blurs past its
/// shape, and the panel's edge cut it off (a hard edge on the left). Fully
/// transparent pixels let clicks through.
let popupMargin: CGFloat = 20

/// Inserts / removes a popup's glass on Config.popup; the panel stays ordered in
/// until the glass is gone.
func popupGlass(_ open: Bool, set: @escaping (Bool) -> Void, removed: @escaping () -> Void) {
  if open { withAnimation(Config.popup) { set(true) }; return }
  withAnimation(Config.popup, completionCriteria: .removed) { set(false) } completion: { removed() }
}

final class GlassMenu {
  let model = MenuModel()
  lazy var host: TrackingHost<MenuView> = {
    let h = TrackingHost(rootView: MenuView(m: model))
    h.onMove = { [weak self] p in self?.hover(p) }
    h.onClick = { [weak self] p, right in if !right { self?.click(p) } }
    return h
  }()
  lazy var panel: NSPanel = {
    let p = barPanel(level: .popUpMenu)
    p.contentView = host
    return p
  }()
  var shownOn: CGDirectDisplayID = 0
  var clicked = Date.distantPast
  var isOpen: Bool { shownOn != 0 }
  /// While open: a click elsewhere or another app coming forward closes it.
  var clickWatch: Any?
  var appWatch: NSObjectProtocol?
  /// the slider is being dragged; every value is shown at once (GlassBar
  /// previews it on all displays), the daemon gets the last one on release
  var dragging = false
  var onPreview: ((CGFloat) -> Void)?
  /// weight.<Weight> | corner.<radius>
  var onSelect: ((String) -> Void)?

  init() {
    model.slide = { [weak self] v in self?.slide(v) }
    model.slideEnded = { [weak self] in self?.slideEnded() }
  }

  func place(on sc: NSScreen, style: BarStyle, strip: CGFloat) {
    model.style = style
    model.scale = max(0.5, (strip - style.gap) / style.island)
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    let f = sc.frame
    // right edge at the islands', top popupOffset below them (the strip's bottom)
    let m = popupMargin
    panel.setFrame(NSRect(x: f.maxX - style.gap - size.width + m, y: f.maxY - strip - style.popupOffset - size.height + m,
                          width: size.width, height: size.height), display: true)
  }

  func show(on did: CGDirectDisplayID, style: BarStyle, strip: CGFloat) {
    guard let sc = screen(did) else { return }
    if model.open { model.open = false } // closing on another display: start over here
    place(on: sc, style: style, strip: strip)
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    shownOn = did
    watchOutside()
    // once the (empty) panel is on screen, so the insertion is seen
    DispatchQueue.main.async {
      guard self.shownOn == did else { return }
      popupGlass(true, set: { self.model.open = $0 }, removed: {})
    }
  }

  /// A new panel's first render takes longer than the animation (the menu
  /// popped in): draw it once, invisible, at start.
  func warm(style: BarStyle, strip: CGFloat) {
    guard !isOpen, let sc = NSScreen.screens.first else { return }
    place(on: sc, style: style, strip: strip)
    model.open = true
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard !self.isOpen else { return }
      self.model.open = false
      self.panel.orderOut(nil)
    }
  }

  func update(style: BarStyle) {
    guard isOpen, style != model.style else { return }
    model.style = style
  }

  func toggle(on did: CGDirectDisplayID, style: BarStyle, strip: CGFloat) {
    if shownOn == did { hide() } else { show(on: did, style: style, strip: strip) }
  }

  /// The bar's own windows get their clicks; a global one is always
  /// elsewhere. Another app coming forward (cmd-N) closes it too — except right
  /// after a click in it: on another display AeroSpace focuses that display on
  /// click.
  func watchOutside() {
    guard clickWatch == nil else { return }
    clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
      [weak self] _ in self?.hide()
    }
    appWatch = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, Date().timeIntervalSince(clicked) > 1 else { return }
      hide()
    }
  }

  func unwatchOutside() {
    if let w = clickWatch { NSEvent.removeMonitor(w) }
    if let w = appWatch { NSWorkspace.shared.notificationCenter.removeObserver(w) }
    clickWatch = nil
    appWatch = nil
  }

  func hide() {
    guard isOpen else { return }
    unwatchOutside()
    shownOn = 0
    model.hover = nil
    popupGlass(false, set: { self.model.open = $0 }) {
      if !self.isOpen { self.panel.orderOut(nil) }
    }
  }

  func hit(_ p: CGPoint?) -> String? {
    guard let p, isOpen else { return nil }
    return model.hits.first { $0.value.contains(p) }?.key
  }

  func hover(_ p: CGPoint?) {
    let id = hit(p)
    if id != model.hover { withAnimation(Config.hover) { model.hover = id } }
  }

  func click(_ p: CGPoint) {
    guard let id = hit(p), id != "corner" else { return }
    clicked = Date()
    onSelect?(id)
  }

  /// The slider moved (in quarter points)
  func slide(_ v: CGFloat) {
    guard isOpen else { return }
    dragging = true
    clicked = Date()
    let v = min(model.style.cornerMax, max(0, (v * 4).rounded() / 4))
    guard v != model.style.corner else { return }
    model.style.corner = v
    onPreview?(v)
  }

  func slideEnded() {
    guard dragging else { return }
    dragging = false
    clicked = Date()
    onSelect?("corner.\(model.style.corner)")
  }
}

class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

func menuLabel(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
  let l = NSTextField(labelWithString: text)
  l.font = font
  l.textColor = color
  return l
}

/// A clickable menu row drawn like the system battery menu's (Control
/// Center's menus: a quiet fill inset 7pt, not the accent capsule NSMenu
/// draws; measured on it at 2x). Tracks the mouse itself: the menu doesn't
/// redraw a view item when its highlight changes.
final class MenuRow: FlippedView {
  let label: NSTextField
  let action: () -> Void
  var hovered = false {
    didSet { if hovered != oldValue { needsDisplay = true } }
  }

  init(_ title: String, action: @escaping () -> Void) {
    label = menuLabel(title, .menuFont(ofSize: 0), .labelColor)
    self.action = action
    super.init(frame: .zero)
    label.sizeToFit()
    label.setFrameOrigin(NSPoint(x: 12, y: 3)) // caps 6pt below the fill's top
    addSubview(label)
    frame = NSRect(x: 0, y: 0, width: label.frame.width + 24, height: 24)
    autoresizingMask = .width // the menu stretches it to its own width
  }

  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for t in trackingAreas { removeTrackingArea(t) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    NSColor.quaternaryLabelColor.setFill()
    let r = NSRect(x: 7, y: 0, width: bounds.width - 14, height: 22)
    NSBezierPath(cgPath: squircle(r, 10.5)).fill()
  }

  override func mouseUp(with event: NSEvent) {
    hovered = false
    enclosingMenuItem?.menu?.cancelTracking()
    action()
  }
}

/// The battery menu: a real NSMenu, like the system's battery menu in the
/// menu bar (header, power source, status, Battery Settings…). Opens on a
/// click on the battery island, below it; updates in place while open.
final class BatteryMenu: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  /// The header, the grey lines and the separator: one view, laid out like
  /// the system battery menu (measured on it at 2x; plain NSMenu items are
  /// 24pt rows at a 17pt inset, a disabled one is grey, an enabled one
  /// highlights): text 15pt from the menu's edge, header caps 16.5pt below
  /// its top, 25pt header → first line, lines 18pt apart, separator 18.75pt
  /// under the last line, Battery Settings… 5pt under it.
  let info = SeparatedView()
  let header = menuLabel("Battery", .systemFont(ofSize: 0, weight: .semibold), .labelColor)
  /// a point smaller than the menu font (12 matches the system's widths to
  /// the pixel), in the disabled item's color (matches it to the pixel)
  let source = menuLabel("", .menuFont(ofSize: 12), .disabledControlTextColor)
  let status = menuLabel("", .menuFont(ofSize: 12), .disabledControlTextColor)
  var isOpen = false

  final class SeparatedView: FlippedView {
    var line: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
      NSColor.separatorColor.setFill()
      NSRect(x: 14, y: line, width: bounds.width - 28, height: 1).fill()
    }
  }

  override init() {
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    for l in [header, source, status] { info.addSubview(l) }
    info.autoresizingMask = .width
    let item = NSMenuItem()
    item.view = info
    menu.addItem(item)
    let settings = NSMenuItem()
    settings.view = MenuRow("Battery Settings…") {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }
    menu.addItem(settings)
  }

  func update(_ b: BatteryState) {
    source.stringValue = "Power Source: " + (b.charge > 0 ? "Power Adapter" : "Battery")
    status.stringValue = b.status
    // (the menu's own padding above the first item: 5pt)
    var w: CGFloat = 0
    for l in [header, source, status] { l.sizeToFit(); w = max(w, l.frame.width) }
    header.setFrameOrigin(NSPoint(x: 12, y: 8))
    source.setFrameOrigin(NSPoint(x: 12, y: 33.5))
    status.setFrameOrigin(NSPoint(x: 12, y: 33.5 + 18))
    info.line = 73
    info.frame = NSRect(x: 0, y: 0, width: w + 24, height: 79)
    info.needsDisplay = true
  }

  /// Below the island, one gap away, like the islands from each other: left
  /// edge on the island's, or, when that runs off the screen, the right edge
  /// one gap from the screen's. anchor: the island, screen coordinates
  /// (bottom-left origin).
  func show(_ b: BatteryState, under anchor: NSRect, gap: CGFloat, screen: NSRect) {
    update(b)
    let x = min(anchor.minX, screen.maxX - gap - menu.size.width)
    // AppKit puts the first item at the point: the menu's own padding above it
    // (5pt on macOS 26, measured) goes on top
    menu.popUp(positioning: nil, at: NSPoint(x: x, y: anchor.minY - gap - 5), in: nil)
  }

  func menuWillOpen(_ menu: NSMenu) { isOpen = true }
  func menuDidClose(_ menu: NSMenu) {
    isOpen = false
    for i in menu.items { (i.view as? MenuRow)?.hovered = false } // no exit event once it's closed
  }
}

// MARK: - Bar

final class GlassBar {
  var state = BarState()
  var models: [CGDirectDisplayID: BarModel] = [:]
  var panels: [CGDirectDisplayID: NSPanel] = [:]
  /// the strip blur's windows, right under the bars' (Config.blurRadius)
  var blurs: [CGDirectDisplayID: NSPanel] = [:]
  let menu = GlassMenu()
  let battery = BatteryMenu()
  var warmed = false
  var onMenuSelect: ((String) -> Void)? {
    get { menu.onSelect }
    set { menu.onSelect = newValue }
  }
  var onPreview: ((CGFloat) -> Void)? {
    get { menu.onPreview }
    set { menu.onPreview = newValue }
  }

  /// The radius slider is being dragged: show the value everywhere at once
  /// (the daemon gets it on release and republishes the same style).
  func preview(corner v: CGFloat) {
    for m in models.values where m.style.corner != v { m.style.corner = v }
  }

  /// Screens changed: re-place the windows (the state names displays by id).
  func screensChanged() {
    menu.hide()
    battery.menu.cancelTracking()
    apply(state, force: true)
  }

  func apply(_ new: BarState, force: Bool = false) {
    var new = new
    if menu.dragging { new.style.corner = menu.model.style.corner } // the slider wins until released
    guard new != state || force else { return }
    let old = state
    state = new
    var seen = Set<CGDirectDisplayID>()
    for d in new.displays {
      guard let sc = screen(d.did) else { continue }
      seen.insert(d.did)
      let m: BarModel
      if let x = models[d.did] { m = x } else {
        // the whole state before the first layout, so every island takes part
        // in the appearance (an island added later just fades in in place)
        m = BarModel(d)
        m.style = new.style
        m.status = new.status
        models[d.did] = m
        panels[d.did] = makePanel(m)
      }
      let p = panels[d.did]!
      let f = sc.frame
      let frame = NSRect(x: f.minX, y: f.maxY - d.strip, width: f.width, height: d.strip)
      if p.frame != frame { p.setFrame(frame, display: true) }
      let before = old.displays.first { $0.did == d.did }
      let moved = before?.spaces != d.spaces
      // only the lens moves (the same cells, one shown elsewhere): it starts
      // with the rest of the switch instead of a layout pass later
      let cellsStay = moved && old.style == new.style && before?.strip == d.strip
        && sameCells(before?.spaces ?? [], d.spaces)
      var ticked = m.status
      ticked.time = new.status.time
      let statusMoves = ticked != new.status
      let update = {
        if m.style != new.style { m.style = new.style }
        if m.display != d { m.display = d }
        if m.status != new.status && !statusMoves { m.status = new.status }
        if cellsStay { withAnimation(Config.lens) { m.lens.target(d.spaces.first { $0.shown }?.n) } }
      }
      if moved { withAnimation(Config.layout, update) } else { update() }
      // the right islands spring to a new layout, a bolt, a new date; the
      // minute tick alone stays unanimated (no frames once a minute)
      if statusMoves { withAnimation(Config.layout) { m.status = new.status } }
      if Config.blurRadius > 0 {
        let b = blurs[d.did] ?? makeBlur(d.did)
        let bf = NSRect(x: frame.minX, y: frame.minY - Config.blurBelow, width: frame.width,
                        height: frame.height + Config.blurBelow)
        if b.frame != bf { b.setFrame(bf, display: true) }
        if new.hidden { b.orderOut(nil) } else if !b.isVisible { b.orderFrontRegardless() }
      }
      if new.hidden { p.orderOut(nil) } else if !p.isVisible { p.orderFrontRegardless() }
      if p.isVisible && !m.appeared {
        sampleBackdrop(only: d.did, why: "bar opens")
        p.contentView?.layoutSubtreeIfNeeded() // the zero-wide layout to spring from
        withAnimation(Config.appear) { m.appeared = true }
      }
    }
    for (did, p) in panels where !seen.contains(did) {
      p.orderOut(nil)
      blurs[did]?.orderOut(nil)
      panels[did] = nil
      blurs[did] = nil
      models[did] = nil
    }
    if new.hidden {
      menu.hide()
      battery.menu.cancelTracking()
    }
    menu.update(style: new.style)
    if !warmed, let d = new.displays.first {
      warmed = true
      if Config.themeMenu { menu.warm(style: new.style, strip: d.strip) }
    }
    if battery.isOpen, let b = new.status.battery { battery.update(b) }
  }

  /// The same cells (numbers, apps, device glyphs), whichever is shown: the
  /// same widths.
  func sameCells(_ a: [SpaceItem], _ b: [SpaceItem]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.n == $1.n && $0.apps == $1.apps && $0.device == $1.device }
  }

  func makePanel(_ m: BarModel) -> NSPanel {
    let p = barPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu))))
    let h = TrackingHost(rootView: BarView(m: m))
    let did = m.did
    h.onMove = { [weak self] pt in self?.hover(did, pt) }
    h.onClick = { [weak self] pt, right in self?.click(did, pt, right: right) }
    p.contentView = h
    return p
  }

  /// One level under the bar's (nothing else lives there), never takes the mouse.
  func makeBlur(_ did: CGDirectDisplayID) -> NSPanel {
    let p = barPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)) - 1))
    p.ignoresMouseEvents = true
    p.contentView = BlurView()
    blurs[did] = p
    return p
  }

  /// The workspace under a point: its cell widened by half the gap between cells.
  func workspace(_ m: BarModel, at p: CGPoint) -> Int? {
    let half = m.style.inset * m.scale / 2
    for (k, r) in m.hits where k.hasPrefix("ws.") {
      if r.insetBy(dx: -half, dy: -half).contains(p) { return Int(k.dropFirst(3)) }
    }
    return nil
  }

  func hover(_ did: CGDirectDisplayID, _ p: CGPoint?) {
    guard let m = models[did] else { return }
    let n = p.flatMap { workspace(m, at: $0) }
    if n != m.hover { withAnimation(Config.hover) { m.hover = n } }
  }

  func click(_ did: CGDirectDisplayID, _ p: CGPoint, right: Bool) {
    guard let m = models[did] else { return }
    if right {
      if Config.themeMenu { menu.toggle(on: did, style: m.style, strip: m.display.strip) }
      return
    }
    menu.hide()
    if let n = workspace(m, at: p) {
      if !(m.display.focused && m.display.spaces.first(where: { $0.n == n })?.shown == true) {
        AeroSpace.run(["workspace", "\(n)"])
      }
    } else if let r = m.hits["battery"], r.contains(p), let b = m.status.battery,
              let f = panels[did]?.frame, let sc = screen(did) {
      let anchor = NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
      battery.show(b, under: anchor, gap: m.style.gap, screen: sc.frame)
    } else if m.hits["input"]?.contains(p) == true {
      nextLayout()
    } else if m.hits["clock"]?.contains(p) == true {
      NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                         configuration: NSWorkspace.OpenConfiguration())
    }
  }

  /// Reads what lies under each shown bar (the wallpaper) and re-picks the
  /// islands' appearance. A display's first read happens as its bar opens.
  /// Every read is logged (backdrop.log): it may light the screen capture dot.
  func sampleBackdrop(only did: CGDirectDisplayID? = nil, why: String) {
    for (d, p) in panels where p.isVisible && (did == nil || did == d) {
      sleepLogLine("display \(d): \(why)", to: Config.state + "/backdrop.log")
      guard let m = models[d],
            let prof = backdropProfile(d, below: CGWindowID((blurs[d] ?? p).windowNumber), height: m.display.strip) else { continue }
      m.backdrop = prof
      m.retone()
    }
  }

  /// System icon theme changed: icons are re-read from NSWorkspace.
  func iconsChanged() {
    iconCache.removeAll()
    for m in models.values { m.iconEpoch += 1 }
  }
}


