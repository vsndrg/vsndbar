import sys
from collections import defaultdict
rows=[l.split() for l in open(sys.argv[1]).read().splitlines() if l.strip()]
t=lambda r:int(r[0])*125/3/1e6
P=1000/120
marks=[t(r) for r in rows if r[1]=='-2']
frames=[t(r) for r in rows if r[1]==sys.argv[2]]
# drops by time since the last mark
hist=defaultdict(int); tot=defaultdict(int)
import bisect
for a,b in zip(frames,frames[1:]):
    if b-a>100: continue
    i=bisect.bisect_right(marks,b)-1
    since=b-marks[i] if i>=0 else 1e9
    bucket='0-50' if since<50 else '50-150' if since<150 else '150-400' if since<400 else '400+'
    k=round((b-a)/P)-1
    tot[bucket]+=1
    if k>0: hist[bucket]+=k
print('marks',len(marks))
for k in ['0-50','50-150','150-400','400+']: print(k,'ms after apply: frames',tot[k],'dropped',hist[k])
# latency apply -> first lens frame
lat=[]
for m in marks:
    i=bisect.bisect_right(frames,m)
    if i<len(frames): lat.append(frames[i]-m)
lat.sort(); print('apply→next lens frame ms: p50 %.1f max %.1f'%(lat[len(lat)//2],lat[-1]) if lat else '')
