# World atlas generator

Builds `App/Fernlet/World/Atlas/WorldAtlas.pack`, the bundled atlas behind the World passport and terrain
(the format and rules are in [Docs/World-Atlas-Pack.md](../../Docs/World-Atlas-Pack.md)). **Build machine
only:** the app never fetches anything. It reads the bundled pack and opens no connection for it, so the
no-tracking wall gains no destination.

## 1. Fetch the sources (once, with the owner's OK)

```sh
Scripts/world-atlas/fetch-sources.sh            # into ~/Library/Caches/Fernlet/atlas-sources
Scripts/world-atlas/fetch-sources.sh <dir>      # or anywhere else
```

The script downloads nine files (eight Natural Earth 1:10m zips, among them the admin-1 states and
provinces added 2026-10-29 for the world view's State zoom, and Beck et al.'s Köppen-Geiger zip, about 114 MB in
all), each into its own new, empty subdirectory, with `curl -fL`. It then checks every file's size and
SHA-256 against the pinned table in the script. A file already in place is only checked again.

The hashes are not pinned yet: every entry reads `UNPINNED`, so a first run prints each computed hash and
exits non-zero. After checking the files, run it with `--record`. That prints the table with the hashes
filled in, ready to paste between the script's `TABLE` lines. Pin them in the same commit as the pack they
build. The coastline zip is for reference and QA only: the generator does not need it.

## 2. Generate

```sh
python3 -I Scripts/world-atlas/build_world_atlas.py \
    --sources ~/Library/Caches/Fernlet/atlas-sources \
    --out App/Fernlet/World/Atlas/WorldAtlas.pack --date 2026-10-30
```

- Python 3.9 standard library, numpy and Pillow only. Under `-I`, the scripts add the user site-packages
  (where numpy and Pillow live on this Mac) at the end of `sys.path`. Nothing else is installed.
- The generator reads the URLs and pins from `fetch-sources.sh`. It refuses a source that differs from its
  pin, and an `UNPINNED` source only gets a note in the summary.
- It runs in minutes and keeps memory well under 4 GB. The fine 1/160° land raster is made one 0.1° row-strip
  at a time.
- **Size cap: 6 MiB** (6,291,456 bytes). An over-size pack is refused and nothing is written.
  `WorldAtlasPackTests` fails one too.
- Output is deterministic for one zlib build: the same sources and options give the same bytes. The only
  date inside is `--date`, which defaults to `unset`.
- The summary prints each section's raw and stored size, the counts, the full sea list (code, token,
  English name, parent ocean, cells), the landmass overrides, notes, unmapped data and the pack's SHA-256.
  **Review the sea list**: it shows which bodies of water count as seas of their own.
- After a regeneration, move `WorldAtlasPack.expectedSHA256` to the printed hash in the same commit.

## 3. Verify

```sh
python3 -I Scripts/world-atlas/selftest.py
```

The self-test writes tiny synthetic sources (shapefiles, dBASE tables and a GeoTIFF, zipped like the real
ones) and builds a 10° pack from them. It decodes the pack with its own independent reader and checks these
rules: land, water and coast states; coast-mask bits; climate majority and nearest fill; the ocean flood (a
bay takes its ocean, a sea polygon its own sea, an enclosed lake 0); a country with a hole; cities with and
without an urban polygon; which urban polygons are kept (one holding a city, one only in a town's reach); the
admin-1 table (ISO 3166-2 tokens, `ne:<id>` for stand-in or shared codes, pieces merged, the country by
`ADM0_A3` or `ISO_A2`, a tiny polygon kept, plate groups by `GEONUNIT`, `REGION_COD` and a county's own code);
determinism; and the size cap. The plate groups themselves (the first-level regions shown where Natural Earth's
admin-1 is second-level) are the hand-written `PLATE_GROUPS` table in the generator.
