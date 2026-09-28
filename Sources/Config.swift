// Geometry, fonts and paths. Everything visual derives from these numbers.

import AppKit
import SwiftUI

enum Config {
  /// One gap everywhere (screen edge → island → window → window → edge, and
  /// between islands). The bar fills the notch strip (safe area = 32pt on the
  /// 16" panel); islands hang from the top edge by `gap` and end flush with the
  /// strip, so they are 32 - gap tall. aerospace.toml gaps use the same number.
  static let bar: CGFloat = 32
  static let gap: CGFloat = 6
  static var island: CGFloat { bar - gap }
  /// Inner pills (workspace cells, the lens) are concentric: inset 3.
  static let inset: CGFloat = 3
  static var pill: CGFloat { island - 2 * inset }

  /// The built-in panel's top corners are physically rounded; the bottom ones
  /// are masked to match with Apple's continuous corner of this radius (the
  /// curve reaches ~1.53 r along each edge). 0 = off.
  static let screenCorner: CGFloat = 21

  /// Corner radius of the islands: one number (the theme menu keeps the
  /// system menu radius), 0 to `cornerMax`. Each shape takes min(radius, its
  /// height / 2): the island caps at a capsule (13); up to 8.5 Apple's
  /// continuous corner still fits the island unclamped (it reaches ~1.53 r
  /// along each edge). With the theme menu on, its slider sets it instead
  /// (Theme keeps the pick) and this is only the default.
  static let corner: CGFloat = 10.5
  static let cornerMax: CGFloat = screenCorner

  /// Popups (theme menu, battery menu) float this far below the islands;
  /// height: a one-row popup (a theme menu row with its padding); radius: the
  /// theme menu's, macOS 26's own menu radius (NSPopupMenuWindow reports 12;
  /// SwiftUI has no default for it: plain glass is a capsule, a
  /// ConcentricRectangle in a borderless panel is square).
  static let popupHeight: CGFloat = 34
  static let popupOffset: CGFloat = 7
  static let popupRadius: CGFloat = 12

  /// Text weight, picked in the right-click menu (Theme keeps the choice):
  /// primary text (workspace digits, date and time, layout, battery level) in
  /// it, secondary (theme menu) one step lighter.
  static let family = "SF Pro Text"
  static let weights = ["Regular", "Medium", "Semibold"]
  static let lighter = ["Regular": "Light", "Medium": "Regular", "Semibold": "Medium"]
  static let weightDefault = "Medium"
  static let textSize: CGFloat = 12.5
  /// the level inside the battery glyph: knocked out of the body, so it
  /// reads thinner than text of the same weight — drawn heavier
  static let batteryText: CGFloat = 11
  /// the battery body past the level (and the nub until full), like the
  /// system's: this much of the full color
  static let batteryTrack: CGFloat = 0.4
  static let batteryWeight = "Semibold"

  /// The right-click theme menu (text weight, corner radius). Off: the bar
  /// keeps the last picks (~/.local/state/vsndbar/theme); the code stays.
  static let themeMenu = false

  /// Low battery (red) at or below this level, off the charger.
  static let batteryLow = 20

  /// A display whose menu bar is lower than the bar gets a shorter strip (the
  /// auto-hidden menu bar must cover the islands when it slides in); 0 = unknown.
  static func strip(menuBar: Int) -> CGFloat { menuBar > 0 ? min(bar, CGFloat(menuBar)) : bar }

  /// Animations (SwiftUI `Animation`; `make install` to apply). Springs:
  /// .bouncy .snappy .smooth, also as .bouncy(duration: 0.4, extraBounce: 0.1),
  /// or .spring(duration: 0.5, bounce: 0.3) (bounce 0 = no overshoot, < 0 =
  /// overdamped); curves: .easeInOut(duration: 0.3), .linear(duration: 0.2)…;
  /// .default; nil = no animation. Any of them faster / slower, same shape:
  /// .bouncy.speed(1.5) (= .bouncy(duration: 0.5 / 1.5); the system's is 0.5).
  /// A spring keeps its speed when it is retargeted mid-flight (quick cmd-N
  /// presses), a curve restarts from rest.
  /// The selection lens (workspaces, theme menu picks).
  static let lens: Animation? = .snappy.speed(2)
  /// Everything else a workspace switch changes: islands growing / shrinking,
  /// cells appearing / leaving, icons, text.
  static let layout: Animation? = .snappy.speed(2)
  /// The bar springing open (daemon start, a new display).
  static let appear: Animation? = .snappy.speed(2)
  /// The theme menu coming in / going out.
  static let popup: Animation? = .snappy.speed(2)
  /// The hover fill following the mouse.
  static let hover: Animation? = .smooth(duration: 0.2)
  /// A display gaining / losing focus: its bar's text and icons brightening / dimming.
  static let focus: Animation? = .smooth(duration: 0.25)
  /// An island switching between the dark and the light appearance.
  static let tone: Animation? = .smooth(duration: 0.1)

  /// Backdrop luminance (relative, 0…1: linear light, 0.18 ≈ mid grey) above
  /// which an island turns light (dark text), and below which it turns back.
  static let lightOn: Float = 0.3
  static let lightOff: Float = 0.2

  /// Text and icons on the bars of displays without focus, like the menu bar
  /// of an inactive display: this much of their opacity (the glass stays).
  static let dimmed: Double = 0.45

  /// Liquid Glass (SwiftUI `Glass`; `make install` to apply): .regular (the
  /// system default), .clear (more see-through: for busy wallpapers, needs
  /// bold content), .identity (no glass at all); any of them tinted:
  /// .regular.tint(.white.opacity(0.3)), .clear.tint(.black.opacity(0.2))…
  /// The islands (workspaces, layout, battery, clock).
  static let islandGlass: Glass = .clear.tint(.black.opacity(0.15))
  /// The theme menu: frosted (it lies over windows,
  /// text must read on anything).
  static let popupGlass: Glass = .regular
  /// The selection lens on the focused workspace, on every bar (and the theme menu's pick):
  /// light glass, like the selected tab's platter in iOS 26. Made interactive
  /// in code (a moving lens needs it).
  static let lensGlass: Glass = .clear.tint(.white.opacity(0.22))
  /// The subdued lens on the workspace a display shows while focus is on another.
  static let lensGlassOther: Glass = .clear

  /// The strip's backdrop: what lies under the bar (the wallpaper) blurred,
  /// like Control Center's, so the islands' glass refracts a blur. The radius
  /// (points; 0 = off) is `blurRadius`, curving up above `blurRise` points
  /// below the screen's top edge to `blurRadiusTop` at the edge; from
  /// `blurHold` points below the strip (negative: inside it) it eases to
  /// none by `blurBelow` points under the strip (its own window, clicks pass
  /// through). The fade's length (blurBelow − blurHold) is its smoothness.
  static let blurRadius: CGFloat = 1
  static let blurRadiusTop: CGFloat = 2
  static let blurRise: CGFloat = 12
  static let blurHold: CGFloat = -32
  static let blurBelow: CGFloat = 56
  /// Saturation after the blur (1 = off): a blur averages colors into grey,
  /// Apple's win them back. Liquid Glass (Control Center): regular 1.3 at
  /// radius 5, clear 1 at 7.2; the old materials (menu 2.2, HUD 1.6, radius
  /// 30) look unnatural at a small radius.
  static let blurSaturation: CGFloat = 1.3

  static let state = NSHomeDirectory() + "/.local/state/vsndbar"
  /// the sketchybar bar's state dir: the theme is carried over from it once
  static let legacyState = NSHomeDirectory() + "/.local/state/sketchybar"

  static let aerospaceApp = "bobko.aerospace"
  static let aerospaceSocket = "/tmp/bobko.aerospace-\(NSUserName()).sock"
  /// pushed state (aerospace patches/bar-state.patch)
  static let aerospaceBarSocket = "/tmp/bobko.aerospace-\(NSUserName())-bar.sock"

  /// Darwin notification `vsndbar toggle` posts (cmd-shift-b).
  static let toggleNotification = "com.vsndrg.vsndbar.toggle"
}
