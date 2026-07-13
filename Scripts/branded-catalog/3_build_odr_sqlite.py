import json, sqlite3, os, uuid, re
SRC="/private/tmp/claude-501/-Users-michaelbowman-Desktop-Fernlet-5-18-Fernlet/55170089-5942-486f-a700-577ae7cd8afc/scratchpad/BrandedODRFoodItems.json"
DB="/private/tmp/claude-501/-Users-michaelbowman-Desktop-Fernlet-5-18-Fernlet/55170089-5942-486f-a700-577ae7cd8afc/scratchpad/FoodCatalogBranded.sqlite"
def norm(s): return re.sub(r'\s+',' ',re.sub(r'[^a-z0-9]',' ',(s or "").lower())).strip()
def norm_gtin(raw):
    d="".join(ch for ch in str(raw or "") if ch.isdigit()); return d.zfill(14) if len(d) in (8,12,13,14) else None
print("loading..."); recs=json.load(open(SRC)); print("records",len(recs))
if os.path.exists(DB): os.remove(DB)
db=sqlite3.connect(DB); db.isolation_level=None
db.execute("PRAGMA page_size=4096;"); db.execute("PRAGMA journal_mode=DELETE;"); db.execute("PRAGMA user_version=2;")
db.executescript("""
CREATE TABLE food (food_id INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL, normalized_name TEXT NOT NULL,
 brand_source TEXT, serving_size REAL NOT NULL, serving_unit TEXT NOT NULL, protein INTEGER NOT NULL, carbs INTEGER NOT NULL,
 fat INTEGER NOT NULL, category TEXT NOT NULL, source TEXT NOT NULL, data_type TEXT NOT NULL, serving_description TEXT,
 verification_policy_days INTEGER NOT NULL, is_flagged INTEGER NOT NULL, micronutrients TEXT, tags TEXT, portions TEXT, gtin_upc TEXT);
CREATE INDEX idx_food_id ON food(id); CREATE INDEX idx_food_normalized_name ON food(normalized_name); CREATE INDEX idx_food_gtin_upc ON food(gtin_upc);
CREATE VIRTUAL TABLE food_fts USING fts5(name, category, tags, content='', columnsize=0, tokenize='unicode61');
""")
MICRO=("fiber","sugar","saturatedFat","cholesterol","sodium","calcium","iron")
db.execute("BEGIN;")
# stable UUID from gtin so ids are deterministic across regenerations (mirrors the app's stable-id intent)
def stable_id(g): return str(uuid.uuid5(uuid.NAMESPACE_OID, "fernlet-branded-"+g))
n=0
for r in recs:
    g=norm_gtin(r["gtinUpc"])
    if not g: continue
    n+=1; nm=norm(r["name"]); micros={k:r[k] for k in MICRO if k in r}
    db.execute("INSERT INTO food VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      (n,stable_id(g),r["name"],nm,r.get("brandSource"),r["servingSize"],r["servingUnit"],
       r["protein"],r["carbs"],r["fat"],r["category"],"usda","branded",None,0,0,
       json.dumps(micros,separators=(",",":")),json.dumps(r.get("tags",["branded"]),separators=(",",":")),"[]",g))
    db.execute("INSERT INTO food_fts(rowid,name,category,tags) VALUES(?,?,?,?)",(n,nm,norm(r["category"]),"branded"))
db.execute("COMMIT;")
db.execute("INSERT INTO food_fts(food_fts) VALUES('optimize');")
db.execute("VACUUM;")
size=os.path.getsize(DB)
print(f"ODR_DB rows={n}  bytes={size}  MB={size/1e6:.1f}")
# sanity: barcode + a search
row=db.execute("SELECT name,gtin_upc FROM food LIMIT 1").fetchone(); print("sample row:",row)
db.close()
