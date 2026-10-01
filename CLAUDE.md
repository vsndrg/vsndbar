# VsndBar: the glass bar (Swift) + AeroSpace

Context file for new sessions. Keep it short; update "Status" and "TODO" as work progresses.
The user speaks Russian; answer in Russian. Details of every change are in `git log` of the repos.
Main goal (user): smooth and cheap on energy. Look and behaviour don't change without asking.

## Repos (each its own git repo)
- `~/.config/vsndbar` — the bar: one Swift process (`Sources/`), `make install` → `~/Applications/VsndBar.app`
  + LaunchAgent `com.vsndrg.vsndbar` + `~/.local/bin/vsndbar` (CLI: `toggle`, `sleep`, `layout`, `screens`).
  State in `~/.local/state/vsndbar/` (theme, sidecar-*, sleep.log, daemon.log).
- `~/.config/aerospace` — `aerospace.toml`, `patches/{back-and-forth,bar-state,menu-bar,monitors,queries,switch-flicker,window-hiding}.patch`,
  `patches/build.sh [--install|--restore]` (source in `~/.cache/aerospace-src`, builds offline)
- `~/.config/sketchybar` — the previous bar (Lua via SbarLua + barhelper), archived: disabled, not uninstalled.
- `~/.config/karabiner` — F6 → `~/.local/bin/vsndbar sleep` (its karabiner.json has the user's own uncommitted edits).
- `~/.config` is also a repo with NO commits and secrets staged (`github-copilot/auth.db`) — don't commit it.

## Architecture
- `Daemon.swift` keeps the state (AeroSpace workspaces, displays, layout, battery, clock, theme, hidden) and
  hands the whole `BarState` to `Bar.swift` (`GlassBar.apply`), which diffs per window. Nothing polls: AeroSpace
  pushes (socket), battery = IOKit power source notifications, layout = TIS notification, displays =
  didChangeScreenParameters (+0.5s settle, menu bar height retries), clock = one timer on each minute boundary.
- AeroSpace → bar: `bar-state.patch` serves `/tmp/bobko.aerospace-$USER-bar.sock`: current state on connect, then
  one JSON line per model change (published from `refreshModel()` and the end of refresh sessions, deduped,
  only the newest kept for a slow reader). The daemon reconnects on AeroSpace's launch notification.
  Bar clicks → `workspace N` over AeroSpace's own command socket (no CLI process).
- Launch: the agent runs `VsndBar launch`, which opens the app as `daemon` through LaunchServices and waits
  for it. Only an app LaunchServices launched gets main thread priority 46 (exec'd by launchd: 31) — the bar
  renders every animation frame on the main thread. Needs `-target arm64-apple-macos26.0` (else -10825).
  Signed with the local `aerospace-local-codesign` cert.
- cmd-shift-b → `vsndbar toggle` → Darwin notification `com.vsndrg.vsndbar.toggle`: swaps the bar and the
  system menu bar. Shown via private SkyLight `SLSSetMenuBarVisibilityOverrideOnDisplay` (dlsym), auto-hide
  stays on. NOT via `_HIHideMenuBar`: that change makes WindowServer pull every window parked in a corner
  fully on screen (~100ms flash, apps too slow to re-hide faster). The override outlives the process →
  cleared at daemon start. visibleFrame still shrinks → AeroSpace menu-bar.patch ignores the menu bar.
  (`launchctl kickstart -k` restarts only the launcher, the old daemon keeps running.)

## Hard constraints (found the hard way, don't re-derive)
Bar:
- The bar = the daemon's windows: one NSPanel per display at the backstopMenu level (-20, the auto-hidden
  menu bar covers it), no fullScreenAuxiliary. Liquid Glass refracts what is behind the window → can't be
  baked into images. One state change = one SwiftUI transaction per window.
- Views take values (`Look`, `SpaceItem`, `StatusState`) and are `Equatable`: a switch re-renders only what
  changed. When only the shown workspace changes (same cells), the lens is retargeted inside the switch's
  own transaction (`Lens.target`); otherwise it follows the layout's reported cell frames (`Lens.follow`).
- Mouse in daemon windows (policy .prohibited, never key): tracking areas activeAlways, acceptsFirstMouse;
  hit testing via frames the SwiftUI layout reports (HitKey), not SwiftUI gestures. Fully transparent
  pixels pass clicks through → the strip has a 0.002-alpha background (right click anywhere opens the menu).
- Glass looks "active" only in a key window, and the panels must never be key. `ActivePanel` overrides the
  private `_hasActiveAppearance` → YES (user approved). becomesKeyOnlyIfNeeded forces the dull look.
- Glass whose frame animates (the lens) must be `.interactive()`, else it re-animates from its old place.
- No public "selection lens" on macOS; `glassEffectID` morph = cross-fade. User rejected hand-made
  morphs/drips → system `.bouncy` only.
- Multi-display: `Display.mon` = NSScreen index = AeroSpace monitor id; windows keyed by CGDirectDisplayID,
  added/removed live, re-placed on didChangeScreenParameters. No restarts.
- Theme menu is OFF (`Config.themeMenu = false`, user: keep only the battery popup; code kept, not deleted):
  right click does nothing, the weight stays the last pick in the theme state (Regular); the island corner is `Config.corner`
  (10.5; the theme file's corner is read only while the menu is on).
- Battery island click → a real `NSMenu` (`BatteryMenu`, user: "like the system battery menu, use the ready-made
  thing"; replaced the glass hover tooltip, deleted). The system's is Control Center's own (grey hover fill, 15pt
  text inset); NSMenu has no such style (status-item association doesn't change it), so both items are VIEWS,
  measured against the system menu at 2x and matched to the half pixel: from the menu top (AppKit adds 5pt above
  the first item) header Semibold 13 at 16.5, grey lines 12pt `disabledControlTextColor` (= a disabled item's
  color to the pixel) at 41.5 / 59.5, separator 1pt `separatorColor` at 78 inset 14, `MenuRow` Battery Settings…
  fill 84–106 inset 7, `quaternaryLabelColor` (~10% white, = system), continuous r 10.5, text 6pt below its
  top, menu bottom 7 below. The menu doesn't redraw view items on highlight → MenuRow tracks the mouse itself
  (tracking area), view items need `autoresizingMask = .width` to span the menu. Menu corner stays NSMenu's 12
  (system's is a bit larger). Placed G below the island, left edge on it or right edge G from the screen edge
  (user: gaps symmetric); AppKit puts the FIRST ITEM at the popUp point → point = island bottom − G − 5. Charge
  limit ("Will Stop Charging at 80%") and energy apps: no public API, left out. While a menu is open the main run
  loop is in event tracking mode: every source/timer that feeds the bar must be in common modes (IOPS source was
  .defaultMode → menu didn't update).
- Theme menu popup: glass panel at popUpMenu level on the display under the mouse.
  Menu: text weight + corner radius slider; picks go straight to `Daemon.menuSelect`, the menu updates in
  place and stays open; closes on a click elsewhere / app activation (ignored right after a menu click:
  AeroSpace focuses the clicked display) — those monitors exist only while it is open. Slider = system
  Slider tracking the mouse itself (its pressed glass knob works in the never-key panel), previews live,
  commits on release (onEditingChanged).
  Popups appear by insertion into a GlassEffectContainer on `.bouncy` + `.materialize`; panels have a 20pt
  transparent margin for the materialize blur. First render of a new panel is slow → warmed at start.
- F6 (Karabiner) → `vsndbar sleep`: ends Sidecar sessions (private SidecarCore `SidecarDisplayManager`,
  else the iPad stays lit), sleeps. Reconnect after wake + unlock lives in the daemon (`SidecarReconnect`,
  also covers lid / idle sleep): iPads connected at willSleep + ones lost in the 30s before it. Lists in
  `~/.local/state/vsndbar/sidecar-{reconnect,lost}` (survive daemon restarts). Log: `sleep.log`.

AeroSpace:
- A hidden workspace remembers its monitor by the monitor's top-left point; a missing monitor maps to the
  nearest one. Sidecar disconnect makes its windows "die" briefly → the closed-windows cache re-homed iPad
  workspaces to main → monitors.patch stores/restores the home point. Rules in the patch: showing a ws while
  its home monitor is missing doesn't re-home it; a moved monitor takes its workspaces along; explicit moves
  (move-workspace-to-monitor, summon) always re-home; a ws still shown on main when its monitor returns goes
  back (happens after sleep).
- Windows are hidden 1pt inside a bottom corner of their monitor; window-hiding.patch picks the corner
  covering the least of other monitors (iPad above the Mac). 0pt inside → macOS pulls it back 40pt.
- Moves windows via AX, per app, async; no atomic switch without SIP. Patches reorder/wait.
- Forgets window→workspace (and ws→monitor) on restart; `build.sh --install` snapshots and restores it.
- Signed with local cert `aerospace-local-codesign` (login keychain) so Accessibility survives rebuilds.
  Build uses Command Line Tools (Xcode license not accepted).

## Design (user decisions)
- One gap G = 6 (`Config.gap`): edge → island → window → window → edge, and between islands; measured from
  the window. Bar h 32 = notch strip. Per display strip = min(32, its menu bar height) (built-in 33, iPad
  30); on a shorter strip the islands are scaled as a whole, gap kept at G. Windows start at 38 built-in /
  36 others, outer.bottom 5 (AeroSpace lays out 1pt short). aerospace.toml gaps must be changed by hand.
- Islands: Liquid Glass (kind in `Config`), continuous corners. Corner radius = ONE number (`Config.corner`,
  0…`screenCorner` 21; with the theme menu on: its slider, saved in the theme state) for the islands, each min(r, h/2).
  Theme menu keeps the system menu radius 12.
- Lens (the ws this display shows) h−6, inset 3: `lensGlass` (.clear + 22% white) on the focused
  display, `lensGlassOther` (.clear) on the others; `.bouncy`, clamped to the island.
- Focus between monitors = like macOS's per-display menu bars: on displays without focus all island
  content (text, icons) is at `Config.dimmed` 45%, glass untouched; fades on `Config.focus`. Tried and
  REJECTED by the user ("непонятно"): the bright lens following focus onto the other bar's
  device-glyph cell + a subdued second lens on what the display shows. Hover: `.primary` fill 50%, same in menu.
- No accent, no active-window border. Text/icons: system label colors.
- Legibility follows the wallpaper like the menu bar: each island is in the light (dark text) or dark
  appearance by the mean luminance under it (`Config.lightOn/lightOff` 0.3/0.2). Read via the private
  CGWindowListCreateImage (dlsym) below the bar's window = wallpaper only (may light the
  screen-capture privacy dot for a moment — seen once, unconfirmed). Only on bar
  open, display change, wallpaper change (watches `~/Library/Application Support/com.apple.wallpaper/Store`,
  ignores rewrites that only bump LastUse); every read logged to `backdrop.log`;
  NOT per minute (user: too costly) → dynamic/aerial wallpapers aren't followed. Status text, theme menu
  items/slider all `.primary` (user: no translucent text there).
- Built-in display bottom corners masked to match the top ones (`Corners`, `screenCorner` 21): static
  layer, hidden on native fullscreen Spaces, `sharingType = .none` (not in screenshots).
- App icons follow the system icon theme: the daemon watches `~/Library/Preferences`; 5–10s lag accepted.
- Text: SF Pro Text, weight from the menu (Regular/Medium/Semibold, secondary one step lighter). Date =
  time weight, "Mon 28 Sep" (English). Battery like the system's: body filled up to the level,
  the rest at `Config.batteryTrack` 40% (user asked: 89% must not look full), level (11pt, `Config.batteryWeight`
  Semibold: knocked-out text reads thin) knocked out of both; bolt = separate image with a scale+fade transition; template
  image, red at ≤20% off AC; menu wording = macOS menu; updates as soon as IOKit reports (user OK'd).
- Right islands animate (`Config.layout`) on any status change except the minute tick alone (no frames per minute).
- Appearance (daemon start, new display): laid out zero wide, then springs open on `.bouncy`.
- Animations are picked in `Config.swift` (`lens`, `layout`, `appear`, `popup`, `hover`; all `.bouncy` except
  hover `.smooth(0.2)`), applied by `make install`.
- Strip blur (user asked: "like Control Center", then "weaker, smoother, a bit lower"): its own panel per display
  (`blurs`, level backstopMenu − 1, ignoresMouseEvents) from the top down to `Config.blurBelow` (56) under the
  strip (under windows it is hidden anyway). `BlurView` = private CABackdropLayer (windowServerAware) + CAFilter
  `variableBlur`, radius shape drawn by the user: `Config.blurRadius` (the middle, user: 1) flat from `blurRise`
  (user: "start the rise a bit earlier" than the islands' top, 6) down to `blurHold` below the strip (user: −32 = the fade
  starts at the screen's top; its length blurBelow − blurHold (user: 88pt) is the smoothness: 25pt read abrupt, 35→135 smooth
  but too low → same length moved up; radius = rise × fade); above
  it rises along e^(1−1/u) BY RATIO (log r interpolated; linear 1→3 over a few pt read as a jump) to
  `blurRadiusTop` (user: 2, blurRise 12) at the screen's edge; below the hold the SQUARE goes down
  the C∞ step S = g(x)/(g(x)+g(1−x)), g = e^(−1/x): share = √(1−S) over the rest of the blurBelow band (a 1–2 px
  blur shows as contrast loss ∝ r²; by ratio it squeezed the visible 1 → 0.4 into ~5pt: user felt an edge at
  47pt) (user: "higher derivatives
  must not jump": u² / smoothstep had curvature jumps at the joins; the saturation mask uses the same fade) (a blur looks strong until its radius is small; linear fade read as a band; a fade across the
  strip put the visible edge mid-island: user "несимметрично"; 10pt band read abrupt). Mask in layer points UNSTRETCHED (a 1px column
  only covered x 0–1): full-size RGBA, alpha = share of the radius, rows top-down. Islands' glass refracts it;
  backdropProfile reads below the blur panel (wallpaper only). User: "мутный" vs Control Center → system
  materials (dumped NSVisualEffectView layers) = sdrNormalize, gaussianBlur 30, colorSaturate 1.6–2.4, scale
  0.125: a blur averages colors into grey, saturation wins them back → `colorSaturate` `Config.blurSaturation`
  after the blur, faded out with it by a gradient mask on the backdrop layer over blurBelow. 1.8 read
  "неестественно": Control Center is Liquid Glass (dumped NSGlassEffectView: `glassBackground` filter, regular =
  blur 5 + face color matrix sat 1.3 / white 1.125 / black 0.08, clear = blur 7.2, sat 1, white 0.8, black
  0.05, scale 0.5) → radius 4, saturation 1.3.
- Glass kinds too: `islandGlass` .clear + 15% black, `popupGlass` .regular (matte: the theme menu lies over
  windows), `lensGlass` .clear + 10% white, `lensGlassOther` .clear + 15% black; lenses made `.interactive()`
  in code.
- Workspaces: every bar shows ALL existing workspaces (occupied or shown); ones living on another monitor
  carry that monitor's device glyph (laptopcomputer / ipad.landscape / display) between digit and icons.
  Right side identical on every monitor. Bar clicks = cmd-N. Layout click = next input source, clock click
  = Calendar.

## Multi-monitor behaviour (agreed spec, implemented in aerospace.toml + patches)
Generic: no hardcoded monitor names/sizes. Typical use: iPad (Sidecar) for Zoom/Telegram.
- cmd-N: focus ws N on the monitor where it lives. N doesn't exist / is hidden and empty → opens on MAIN.
  cmd-N on the focused N → back to the previously focused ws (any monitor; toggle of two; nothing if it
  is gone: back-and-forth.patch). Bar clicks don't go back.
- cmd-alt-N: `summon-workspace N` to the focused monitor; the monitor it left shows another of its own
  non-empty workspaces, else a fresh stub (11, 12…).
- cmd-shift-N: move window to ws N wherever it lives; focus stays.
- cmd-shift-h/l: move the WHOLE focused workspace to the next/prev monitor; focus and cursor stay.
- Cursor: `move-mouse monitor-lazy-center` via exec-and-forget (runs after the whole binding).
- Disconnect: its workspaces move to main. Reconnect: they return (monitors.patch).

## Measuring (tools/bench, see bench.sh header)
- Frame probe: lens frame times recorded in `LensFrame.body` (probe build only), gaps > 1.5 periods at
  120 Hz = drops. Noisy run to run (±2%): compare several runs. Over half the recorded frames are the
  spring's sub-pixel tail (< 2 pt/s); drops there are invisible.
- bench.sh sends SIGUSR1 (probe dump): the regular build dies on it → run it against the probe build only.
  WindowServer's rusage is not readable (410 ERR); `ps -o cputime=` of it works.
- Strip blur cost (2026-09-29, blur on vs blurRadius 0, alternating ×2, idle 60s + 20 switches): bar process
  same (switch 390–399 vs 384–390 mJ), WindowServer CPU +2–3% (idle ~7.2 vs ~7.0 s/min, switch 4.1 vs 4.0 s;
  noisy). WindowServer GPU not measurable without sudo (powermetrics).
- Visual check: `screencapture -x -R x,y,w,h` / `-v`; diff with PIL/numpy (venv in the scratchpad). Judge
  glass over the wallpaper, not over windows. Real mouse: post `CGEvent`s (small Swift scripts).

## Status (2026-09-28)
Rewrite done and running (sketchybar disabled). Verified: pixel-identical to the old bar on both displays
(same state), clicks, theme menu picks + close, tooltip, toggle, crash restart. 20 switches 1↔3 (iPad
connected): old — 296 processes spawned, lens drops 12%, worst gap 51 ms; now — 98 (20 of them the
benchmark's own `aerospace` CLI calls), drops 0.8–1.2%, worst gap ~20 ms, bar energy ~0.9 J (old bar
process 1.2 J + Lua + its processes). Idle: 20 wakeups/min (old: ~143).

## Open issues / TODO
- Not tested yet by hand: Sidecar connect/disconnect (bars appear/vanish), F6 / lid sleep reconnect.
- Energy idea, NOT applied (touches "system .bouncy only"): SwiftUI runs `.bouncy` ~1.3s until 0.001pt;
  ending the lens spring at 0.05pt (same Spring math via CustomAnimation, additive merge = same retarget)
  would cut ~⅓ of switch frames invisibly. Ask the user first.
- Second display: lower accordion window flashes on switch (AeroSpace). Planned: confirmed ordering instead
  of timeouts — per monitor; place + confirm the top window before revealing lower accordion windows; hide
  old windows top-down only after the ones below are gone; ~1s timeout as liveness fallback only.
- summon-workspace from an EMPTY ws on another monitor once landed on main (AeroSpace native-focus race).
