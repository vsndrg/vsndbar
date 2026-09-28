// The built-in display's bottom corners, masked to match the physically
// rounded top ones.

import AppKit

/// The built-in panel's top corners are physically rounded, the bottom ones
/// are not: mask the bottom corners with black so all four match. Only the
/// built-in display (CGDisplayIsBuiltin); rebuilt when screens change.
final class Corners {
  let radius: CGFloat
  var windows: [NSWindow] = []
  var display: CGDirectDisplayID = 0

  /// radius of Apple's continuous corner (the curve reaches ~1.53 r along each edge)
  init(radius: CGFloat) { self.radius = radius }

  /// Black outside the continuous corner, rendered once: the window shows it as
  /// static layer contents (no draw() calls, nothing to redraw).
  func mask(_ s: CGFloat, scale: CGFloat, right: Bool) -> CGImage? {
    let px = Int((s * scale).rounded())
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    // a big rect whose bottom-left / bottom-right corner sits in this window
    ctx.setBlendMode(.clear)
    ctx.addPath(squircle(CGRect(x: right ? s - 4 * s : 0, y: 0, width: 4 * s, height: 4 * s), radius))
    ctx.fillPath()
    return ctx.makeImage()
  }

  func update() {
    windows.forEach { $0.orderOut(nil) }
    windows = []
    display = 0
    guard radius > 0,
          let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin(displayID($0)) != 0 }) else { return }
    display = displayID(screen)
    let s = ceil(radius * 1.53) + 1
    for right in [false, true] {
      let f = screen.frame
      let frame = NSRect(x: right ? f.maxX - s : f.minX, y: f.minY, width: s, height: s)
      let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.ignoresMouseEvents = true
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
      // like the physical top corners, keep them out of screenshots
      w.sharingType = .none
      let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
      view.wantsLayer = true
      view.layerContentsRedrawPolicy = .never
      view.layer?.contents = mask(s, scale: screen.backingScaleFactor, right: right)
      view.layer?.contentsScale = screen.backingScaleFactor
      w.contentView = view
      windows.append(w)
    }
    refresh()
  }

  /// Hidden while the built-in display shows a fullscreen app (the corners
  /// would sit on top of its content, and cost the fullscreen fast path).
  func refresh() {
    let hide = display != 0 && showsFullscreenSpace(display)
    for w in windows {
      if hide { w.orderOut(nil) } else { w.orderFrontRegardless() }
    }
  }
}

