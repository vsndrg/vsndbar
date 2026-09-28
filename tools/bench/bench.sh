#!/bin/bash
# Energy / smoothness measurements (see CLAUDE.md "Measuring").
#   ./build-probe.sh                 VsndBarProbe.app: the app + a lens frame probe (probe.swift)
#   open -g --env PROBE_OUT=$PWD/x.frames VsndBarProbe.app --args daemon   (stop the agent first)
#   ./bench.sh LABEL $(pgrep -x VsndBar)   idle 60s, then 20 switches 1<->3: CPU, wakeups,
#                                    energy, processes spawned; SIGUSR1 dumps the probe's frames
#   python3 frames.py x.frames [key] dropped lens frames; drops.py x.frames key: by time since a switch
#   ./exp.sh NAME 'python edit of new/Bar.swift'   A/B an experiment on 20 empty-workspace switches
set -u
B="$(cd "$(dirname "$0")" && pwd)"; L=$1; shift; PIDS="$*"
[ -x "$B/rusage" ] || swiftc -O "$B/rusage.swift" -o "$B/rusage"
lastpid() { /usr/bin/true & wait $!; echo $!; }
snap() { "$B/rusage" $PIDS $(pgrep -x AeroSpace) > "$B/$L.$1"; }
DP=$(pgrep -x VsndBar || pgrep -f 'probe daemo[n]')
echo "== idle 60s"
snap i0; p0=$(lastpid); sleep 60; p1=$(lastpid); snap i1
echo "spawned (system-wide) $((p1-p0-1))"
paste "$B/$L.i0" "$B/$L.i1" | awk '{printf "%-16s cpu %8.1f ms  wakeups %5d  energy %8.1f mJ\n",$2,$10-$3,$12-$5,$14-$7}'
echo "== switch x20"
kill -USR1 $DP 2>/dev/null; sleep 0.3
snap s0; p0=$(lastpid)
for i in $(seq 10); do aerospace workspace 3; sleep 1; aerospace workspace 1; sleep 1; done
p1=$(lastpid); snap s1
kill -USR1 $DP; sleep 0.5
echo "spawned (system-wide, incl. 20 aerospace CLI) $((p1-p0-1))"
paste "$B/$L.s0" "$B/$L.s1" | awk '{printf "%-16s cpu %8.1f ms (+child %7.1f)  wakeups %5d  energy %8.1f mJ\n",$2,$10-$3,$11-$4,$12-$5,$14-$7}'
