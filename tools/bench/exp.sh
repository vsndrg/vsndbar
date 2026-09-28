#!/bin/bash
# exp.sh NAME PYEDIT : probe build with an extra edit of new/Bar.swift, run 20 empty-ws switches
B="$(cd "$(dirname "$0")" && pwd)"; N=$1; EDIT=$2
$B/build-probe.sh >/dev/null || exit 1
python3 -c "$EDIT" "$B/new/Bar.swift" || exit 1
swiftc -O -target arm64-apple-macos26.0 -framework AppKit -framework Carbon -framework SwiftUI -framework IOKit $B/new/*.swift $B/probe.swift -o $B/VsndBarProbe.app/Contents/MacOS/VsndBar || exit 1
codesign --force --sign aerospace-local-codesign $B/VsndBarProbe.app 2>/dev/null
pkill -x VsndBar; sleep 0.5; open -g --env PROBE_OUT=$B/$N.frames $B/VsndBarProbe.app --args daemon; sleep 3
aerospace workspace 6; sleep 1.5; kill -USR1 $(pgrep -x VsndBar); sleep 0.3
for i in $(seq 10); do aerospace workspace 9; sleep 1; aerospace workspace 6; sleep 1; done
kill -USR1 $(pgrep -x VsndBar); sleep 0.5; aerospace workspace 1
K=$(awk '$2>0{print $2}' $B/$N.frames | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "== $N"; python3 $B/frames.py $B/$N.frames $K | tail -1; python3 $B/drops.py $B/$N.frames $K
