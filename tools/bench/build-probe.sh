#!/bin/bash
# builds $B/VsndBarProbe.app from ~/.config/vsndbar with the lens frame probe
set -e
B="$(cd "$(dirname "$0")" && pwd)"
rm -rf $B/new $B/VsndBarProbe.app; mkdir -p $B/new; cp ~/.config/vsndbar/Sources/*.swift $B/new/
python3 - "$B/new" <<'PY'
import sys
d=sys.argv[1]
p=d+'/Bar.swift'; s=open(p).read()
old="    let l = max(0, min(lo, maxX)), r = max(l, min(hi, maxX))\n"
assert old in s; s=s.replace(old,"    Probe.frame(lo, hi, key: maxX)\n"+old,1); open(p,'w').write(s)
old="  func apply(_ new: BarState, force: Bool = false) {\n"
assert old in s; s=s.replace(old,old+"    Probe.mark(-2)\n",1); open(p,'w').write(s)
p=d+'/Daemon.swift'; s=open(p).read()
old="    NSApplication.shared.setActivationPolicy(.prohibited)\n"
assert old in s; s=s.replace(old,old+"    Probe.start()\n",1); open(p,'w').write(s)
PY
cp -R ~/.config/vsndbar/build/VsndBar.app $B/VsndBarProbe.app
swiftc -O -target arm64-apple-macos26.0 -framework AppKit -framework Carbon -framework SwiftUI -framework IOKit \
  $B/new/*.swift $B/probe.swift -o $B/VsndBarProbe.app/Contents/MacOS/VsndBar
codesign --force --sign aerospace-local-codesign $B/VsndBarProbe.app 2>/dev/null
