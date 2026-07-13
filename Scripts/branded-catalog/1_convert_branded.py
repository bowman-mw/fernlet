import json, sys, os
PATH="/Users/michaelbowman/Downloads/FoodData_Central_branded_food_json_2026-04-30.json"
OUT_FULL="/private/tmp/claude-501/-Users-michaelbowman-Desktop-Fernlet-5-18-Fernlet/55170089-5942-486f-a700-577ae7cd8afc/scratchpad/BrandedFoodItems.json"

def norm_gtin(raw):
    if not raw: return None
    d="".join(ch for ch in str(raw) if ch.isdigit())
    return d.zfill(14) if len(d) in (8,12,13,14) else None

def clean_name(desc):
    if not desc: return None
    # collapse the USDA repeated comma-clause pattern; keep first occurrence order
    parts=[p.strip() for p in desc.split(",")]
    seen=set(); uniq=[]
    for p in parts:
        key=p.lower()
        if p and key not in seen:
            seen.add(key); uniq.append(p)
    s=", ".join(uniq)
    s=s.replace('""','"').strip(' "')
    # title-case tokens that aren't already-uppercase acronyms or numeric
    ACRONYMS={"BBQ","RTD","USA","UHT","GMO","MCT","DHA","EPA","XL"}
    def tc(w):
        if any(c.isdigit() for c in w): return w
        core=w.strip("().,&/")
        if core.upper() in ACRONYMS: return w.upper()
        return w[:1].upper()+w[1:].lower() if w else w
    s=" ".join(tc(w) for w in s.split())
    return s[:120] if s else None

def lv(ln,k):
    v=(ln or {}).get(k); return (v or {}).get("value") if isinstance(v,dict) else None

def completeness(o):
    ln=o.get("labelNutrients") or {}
    return sum(1 for k in ("protein","carbohydrates","fat","fiber","sugars","saturatedFat","cholesterol","sodium","calcium","iron","calories") if lv(ln,k) is not None)

def convert(o):
    g=norm_gtin(o.get("gtinUpc"))
    if not g: return None
    name=clean_name(o.get("description",""))
    if not name: return None
    ln=o.get("labelNutrients") or {}
    per100={fn.get("nutrient",{}).get("id"):fn.get("amount") for fn in o.get("foodNutrients",[])}
    ss=o.get("servingSize"); su=o.get("servingSizeUnit") or "g"
    if not (ss and ss>0): ss=100.0; su="g"
    scale=ss/100.0
    def macro(lk,nid):
        v=lv(ln,lk)
        if v is not None: return round(float(v))
        p=per100.get(nid)
        return round(float(p)*scale) if p is not None else 0
    rec={
      "name": name,
      "brandSource": (o.get("brandOwner") or o.get("brandName") or None),
      "gtinUpc": g,
      "servingSize": round(float(ss),2),
      "servingUnit": su,
      "protein": macro("protein",1003),
      "carbs": macro("carbohydrates",1005),
      "fat": macro("fat",1004),
      "category": (o.get("brandedFoodCategory") or "Branded")[:60],
      "dataType": "Branded",
      "tags": ["branded"],
    }
    for lk,ck in [("fiber","fiber"),("sugars","sugar"),("saturatedFat","saturatedFat"),
                  ("cholesterol","cholesterol"),("sodium","sodium"),("calcium","calcium"),("iron","iron")]:
        v=lv(ln,lk)
        if v is not None: rec[ck]=round(float(v),2)
    if rec["brandSource"] is None: del rec["brandSource"]
    return rec

best={}  # gtin -> (completeness, record)
total=kept=0
with open(PATH) as f:
    f.readline()
    for line in f:
        s=line.strip().rstrip(",")
        if not s.startswith("{"): continue
        try: o=json.loads(s)
        except: continue
        total+=1
        if o.get("marketCountry")!="United States": continue
        c=completeness(o)
        # need at least macros
        ln=o.get("labelNutrients") or {}
        has_macro = any(lv(ln,k) is not None for k in ("protein","carbohydrates","fat")) or bool({1003,1004,1005} & set({fn.get("nutrient",{}).get("id") for fn in o.get("foodNutrients",[])}))
        if not has_macro: continue
        r=convert(o)
        if not r: continue
        g=r["gtinUpc"]
        prev=best.get(g)
        if prev is None or c>prev[0]:
            best[g]=(c,r)
        if total % 100000 == 0:
            print(f"...scanned {total}, unique {len(best)}", file=sys.stderr)
records=[v[1] for v in best.values()]
with open(OUT_FULL,"w") as out:
    json.dump(records, out, separators=(",",":"))
print("SCANNED", total)
print("UNIQUE_KEPT", len(records))
print("OUT_BYTES", os.path.getsize(OUT_FULL))
print("OUT_MB", round(os.path.getsize(OUT_FULL)/1e6,1))
# sample
for r in records[:5]:
    print("SAMPLE:", json.dumps(r))
