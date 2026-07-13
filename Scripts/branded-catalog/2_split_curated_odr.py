import json, os
from collections import defaultdict
SRC="/private/tmp/claude-501/-Users-michaelbowman-Desktop-Fernlet-5-18-Fernlet/55170089-5942-486f-a700-577ae7cd8afc/scratchpad/BrandedFoodItems.json"
OUT_DIR="/private/tmp/claude-501/-Users-michaelbowman-Desktop-Fernlet-5-18-Fernlet/55170089-5942-486f-a700-577ae7cd8afc/scratchpad"
CURATED_TARGET=50000
MICRO=("fiber","sugar","saturatedFat","cholesterol","sodium","calcium","iron")
recs=json.load(open(SRC))
def completeness(r): return sum(1 for k in MICRO if k in r) + (1 if r.get("brandSource") else 0) + (1 if r.get("protein") or r.get("carbs") or r.get("fat") else 0)
# group by category, sort each by completeness desc then name
bycat=defaultdict(list)
for r in recs: bycat[r["category"]].append(r)
for c in bycat: bycat[c].sort(key=lambda r:(-completeness(r), r["name"]))
# round-robin across categories (breadth) until target
cats=sorted(bycat, key=lambda c:-len(bycat[c]))
curated=[]; idx={c:0 for c in cats}
picking=True
while len(curated)<CURATED_TARGET and picking:
    picking=False
    for c in cats:
        i=idx[c]
        if i < len(bycat[c]):
            curated.append(bycat[c][i]); idx[c]=i+1; picking=True
            if len(curated)>=CURATED_TARGET: break
curated_gtins={r["gtinUpc"] for r in curated}
odr=[r for r in recs if r["gtinUpc"] not in curated_gtins]
json.dump(curated, open(os.path.join(OUT_DIR,"BrandedCuratedFoodItems.json"),"w"), separators=(",",":"))
json.dump(odr, open(os.path.join(OUT_DIR,"BrandedODRFoodItems.json"),"w"), separators=(",",":"))
print("TOTAL", len(recs))
print("CURATED", len(curated), "categories", len(set(r['category'] for r in curated)))
print("ODR", len(odr))
print("CURATED_MB", round(os.path.getsize(os.path.join(OUT_DIR,'BrandedCuratedFoodItems.json'))/1e6,1))
print("ODR_MB", round(os.path.getsize(os.path.join(OUT_DIR,'BrandedODRFoodItems.json'))/1e6,1))
# category spread sanity in curated
from collections import Counter
top=Counter(r["category"] for r in curated).most_common(8)
print("curated top cats:", top)
