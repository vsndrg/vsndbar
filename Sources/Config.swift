// Geometry, fonts and paths. Everything visual derives from these numbers.

import AppKit

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

  /// Corner radius: one number for islands and the tooltip (the menu keeps the
  /// system menu radius), set with the slider in the right-click menu (Theme
  /// keeps it), from 0 to the built-in panel's own radius. Each shape takes
  /// min(radius, its height / 2): the island caps at a capsule (13). Default
  /// h / (2 * 1.528): the largest radius at which Apple's continuous corner
  /// still fits the island unclamped.
  static let cornerDefault: CGFloat = (island / (2 * 1.528) * 4 + 0.5).rounded(.down) / 4
  static let cornerMax: CGFloat = screenCorner

  /// Popups (battery tooltip, theme menu) float this far below the islands;
  /// height: a one-row popup (a theme menu row with its padding); radius: the
  /// theme menu's, macOS 26's own menu radius (NSPopupMenuWindow reports 12;
  /// SwiftUI has no default for it: plain glass is a capsule, a
  /// ConcentricRectangle in a borderless panel is square).
  static let popupHeight: CGFloat = 34
  static let popupOffset: CGFloat = 7
  static let popupRadius: CGFloat = 12

  /// Text weight, picked in the right-click menu (Theme keeps the choice):
  /// primary text (workspace digits, date and time, layout, battery level) in
  /// it, secondary (tooltip, menu) one step lighter.
  static let family = "SF Pro Text"
  static let weights = ["Regular", "Medium", "Semibold"]
  static let lighter = ["Regular": "Light", "Medium": "Regular", "Semibold": "Medium"]
  static let weightDefault = "Medium"
  static let textSize: CGFloat = 12.5
  /// the level inside the battery glyph
  static let batteryText: CGFloat = 10

  /// Low battery (red) at or below this level, off the charger.
  static let batteryLow = 20

  /// A display whose menu bar is lower than the bar gets a shorter strip (the
  /// auto-hidden menu bar must cover the islands when it slides in); 0 = unknown.
  static func strip(menuBar: Int) -> CGFloat { menuBar > 0 ? min(bar, CGFloat(menuBar)) : bar }

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
