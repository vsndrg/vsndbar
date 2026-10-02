# VsndBar

A Liquid Glass bar for [AeroSpace](https://github.com/nikitabobko/AeroSpace) on macOS 26+, in place of the menu
bar: every workspace with its app icons (and the monitor it lives on), the keyboard layout, battery and clock — on
every display. One Swift process: AeroSpace pushes its state over a socket, everything else comes from system
notifications, nothing polls.

It needs the patched AeroSpace from [vsndrg/aerospace](https://github.com/vsndrg/aerospace).
[vsnd-setup](https://github.com/vsndrg/vsnd-setup) installs both in one command:

```sh
curl -fsSL https://raw.githubusercontent.com/vsndrg/vsnd-setup/main/install.sh | bash
```

## By hand

```sh
make install     # build, copy to ~/Applications, (re)start the LaunchAgent
make uninstall
```

Command Line Tools are enough. The menu bar must hide automatically (the bar lives under it).

## CLI

`~/.local/bin/vsndbar`:

| | |
|---|---|
| `toggle` | swap the bar and the system menu bar (`cmd-shift-b` in the AeroSpace config) |
| `sleep` | end Sidecar sessions, then sleep; they reconnect after wake (`F6` via Karabiner) |
| `layout [next]` | print / switch the input source |
| `screens` | list the displays |

Settings (glass, gap, corner radius, animations) are in [`Sources/Config.swift`](Sources/Config.swift); logs in
`~/.local/state/vsndbar/`.
