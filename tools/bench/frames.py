import sys
# mach ticks on Apple silicon: 125/3 ns
rows=[l.split() for l in open(sys.argv[1]).read().splitlines() if l.strip()]
from collections import Counter
key=Counter(r[1] for r in rows).most_common(1)[0][0] if len(sys.argv)<3 else sys.argv[2]
print('keys',Counter(r[1] for r in rows),'using',key)
t=[int(r[0])*125/3/1e6 for r in rows if r[1]==key]
P=1000/120
bursts=[];cur=[t[0]] if t else []
for a,b in zip(t,t[1:]):
    if b-a>100: bursts.append(cur);cur=[b]
    else: cur.append(b)
if cur: bursts.append(cur)
frames=drops=0;worst=0;gaps=[]
for bu in bursts:
    for a,b in zip(bu,bu[1:]):
        g=b-a;gaps.append(g);frames+=1
        k=round(g/P)-1
        if k>0: drops+=k
        worst=max(worst,g)
gaps.sort()
print(f"bursts {len(bursts)} frames {frames} dropped {drops} ({100*drops/max(1,frames+drops):.1f}%) worst gap {worst:.1f}ms p50 {gaps[len(gaps)//2]:.2f} p99 {gaps[int(len(gaps)*.99)]:.2f}")
