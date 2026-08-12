# Self-hosted fonts

The site loads **no external resources** — the CSP in `../_headers` sets `font-src 'self'`,
so the design-system fonts must live here. Drop these five files in this folder:

| File | Family | Where to get it |
| --- | --- | --- |
| `Fraunces.woff2` | Fraunces (variable, wght 600 used) | [Google Fonts](https://fonts.google.com/specimen/Fraunces) |
| `DMSerifDisplay-Regular.woff2` | DM Serif Display | [Google Fonts](https://fonts.google.com/specimen/DM+Serif+Display) |
| `InstrumentSerif-Regular.woff2` | Instrument Serif | [Google Fonts](https://fonts.google.com/specimen/Instrument+Serif) |
| `InstrumentSerif-Italic.woff2` | Instrument Serif Italic | same |
| `DMSans.woff2` | DM Sans (variable, wght 400–500 used) | [Google Fonts](https://fonts.google.com/specimen/DM+Sans) |
| `PlayfairDisplay-Italic.woff2` | Playfair Display Italic (wordmark only) | [Google Fonts](https://fonts.google.com/specimen/Playfair+Display) |

All six are SIL Open Font License 1.1 — redistribution in this repo is permitted.
Keep the OFL license text alongside them (`OFL.txt`) when you add the files.

Easiest way to get `.woff2` builds: download the TTFs from Google Fonts and convert with
[`woff2_compress`](https://github.com/google/woff2), or use the `.woff2` URLs that
`fonts.googleapis.com/css2?...` returns in a browser and save those files directly.

## Until the files are here

`style.css` declares each `@font-face` with a fallback stack, so the site renders correctly
with system serifs and sans-serifs if the files are missing — it just won't be on-brand.
Nothing 404s in a way that breaks the page.
