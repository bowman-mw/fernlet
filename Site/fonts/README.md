# Self-hosted fonts

The site loads **no external resources** — the CSP in `../_headers` sets `font-src 'self'`,
so the design-system fonts must live here. Drop these six files in this folder:

| File | Family | Where to get it |
| --- | --- | --- |
| `Fraunces.woff2` | Fraunces (variable, wght 600 used) | [Google Fonts](https://fonts.google.com/specimen/Fraunces) |
| `DMSerifDisplay-Regular.woff2` | DM Serif Display | [Google Fonts](https://fonts.google.com/specimen/DM+Serif+Display) |
| `InstrumentSerif-Regular.woff2` | Instrument Serif | [Google Fonts](https://fonts.google.com/specimen/Instrument+Serif) |
| `InstrumentSerif-Italic.woff2` | Instrument Serif Italic | same |
| `DMSans.woff2` | DM Sans (variable, wght 400–500 used) | [Google Fonts](https://fonts.google.com/specimen/DM+Sans) |
| `PlayfairDisplay-Italic.woff2` | Playfair Display Italic (wordmark only) | [Google Fonts](https://fonts.google.com/specimen/Playfair+Display) |

## Licenses

All five families are under the SIL Open Font License 1.1. The site may serve them only if each
family's copyright notice and license sit beside its files, so when you add a family's `.woff2`,
copy its license from [`App/Fernlet/Fonts/LICENSES/`](../../App/Fernlet/Fonts/LICENSES) into this
folder in the same commit:

| Font files | License file |
| --- | --- |
| `Fraunces.woff2` | `Fraunces-OFL.txt` |
| `DMSerifDisplay-Regular.woff2` | `DMSerifDisplay-OFL.txt` |
| `InstrumentSerif-Regular.woff2`, `InstrumentSerif-Italic.woff2` | `InstrumentSerif-OFL.txt` |
| `DMSans.woff2` | `DMSans-OFL.txt` |
| `PlayfairDisplay-Italic.woff2` | `PlayfairDisplay-OFL.txt` |

The Pages workflow will not deploy a `.woff2` in this folder without its license file.

## Making the `.woff2` files

Download the family from Google Fonts and convert the unmodified TTF with
[`woff2_compress`](https://github.com/google/woff2), which only compresses. For the three families
`style.css` loads as `woff2-variations`, convert the variable font: `Fraunces[SOFT,WONK,opsz,wght].ttf`,
`DMSans[opsz,wght].ttf` and `PlayfairDisplay-Italic[wght].ttf`.

Don't subset, instance or otherwise edit a font on the way. The OFL counts any of that as a
Modified Version (OFL FAQ 2.2 and 2.6), and Playfair Display reserves its name, so a modified copy
could not be served as "Playfair Display". Two shortcuts produce modified files, so avoid both:

- saving the `.woff2` files that `fonts.googleapis.com/css2?...` returns, which are subsets;
- converting the app's bundled Fraunces, DM Sans or Playfair Display TTFs, which are static
  instances made from the variable fonts.

## Until the files are here

`style.css` declares each `@font-face` with a fallback stack, so the site renders correctly
with system serifs and sans-serifs if the files are missing — it just won't be on-brand.
Nothing 404s in a way that breaks the page.
