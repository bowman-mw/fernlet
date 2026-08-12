# fernlet.com — static site

The entire public web presence for Fernlet. **Static files only, forever** — the app's
"no servers anyone operates" rule applies here: no server-side code, no analytics, no cookies,
no external requests (enforced by the CSP, which ships both as a `<meta http-equiv>` in every page
and as a header rule in `_headers`).

Every page **renders completely with JavaScript disabled.** `app.js` is progressive
enhancement only — the companion poke, the friend-mesh walkthrough, the app-screen tabs, the
backup toggle and the collapsing nav. It sets no cookies, writes no storage, and makes no
requests. Fonts, styles and script are all served from this origin.

## Contents

| Path | Purpose |
| --- | --- |
| `index.html` | Landing page — the companion, the friend mesh, period tracking, the privacy architecture, FAQ, roadmap. |
| `privacy/index.html` | The privacy policy — **generated from [`Docs/Privacy-Policy.md`](../Docs/Privacy-Policy.md)**, which stays the source of truth. When the policy changes, regenerate this page (and update `Fernlet/PrivacyPolicyView.swift`) so all three copies match. This URL goes in App Store Connect as the Privacy Policy URL. |
| `support/index.html` | Support/contact page — the ASC Support URL. |
| `404.html` | Not-found page (both GitHub Pages and Cloudflare Pages pick it up automatically). |
| `style.css` | The whole site's styling, light **and** dark (`prefers-color-scheme`, no toggle — it follows the OS). Design tokens mirror the Fernlet Design System (parchment/cream/bark/moss, Fraunces + DM Serif Display + Instrument Serif + DM Sans); the dark palette is the app's own (`FernletThemeDefaults`). |
| `app.js` | Progressive-enhancement interactions. Optional by construction. |
| `assets/` | The brand mark and the favicons. `fernlet-mark-header.svg` is the nav/footer logo; `fernlet-mark-header-dark.svg` is the same mark with the bark-brown branch recoloured to pale sage (`#C8DBC2`, the app's own dark-icon treatment) because the brown vanishes on the dark ground — the pages pick between them with `<picture media="(prefers-color-scheme:dark)">`. `favicon.svg` is the tab icon, with `favicon-32.png` / `favicon-16.png` as the raster fallback and `apple-touch-icon.png` (180px) for iOS home screens. All five come from the app icon set, so the tab, the header and the App Store icon are the same mark. |
| `fonts/` | Self-hosted woff2 files — see [`fonts/README.md`](fonts/README.md) for what to drop in. |
| `_headers` | Cloudflare/Netlify header rules: security baseline + font caching + the `application/json` content-type rule for the future AASA file. **Ignored by GitHub Pages** (see below). |
| `.nojekyll` | Stops any Jekyll processing, so `_headers` and future `_`-prefixed paths publish verbatim. |

## Keeping the policy honest

`privacy/index.html` is a **generated** page. The same policy text is pinned in three places and
they must always match:

1. `Docs/Privacy-Policy.md` — the source of truth
2. `Fernlet/PrivacyPolicyView.swift` — the in-app copy
3. `Site/privacy/index.html` — the hosted copy (the App Store Connect Privacy Policy URL)

`FernletTests/PrivacyPolicyParityTests` pins the effective date and the load-bearing clauses across
all three, and the Pages workflow re-checks the same thing before every deploy — so a stale hosted
policy fails the deploy instead of going live. Any material change: update all three and bump the
effective date in all three.

## Still to do

1. **Add the font files** listed in [`fonts/README.md`](fonts/README.md). The site degrades to
   system serifs without them, so this is not blocking — but it is not on-brand until done.
2. **Swap in real screenshots.** The phone mock on the landing page is a faithful HTML
   recreation of the Home / Journal / Food screens, not a capture. Once there are simulator
   shots worth showing, replace it (and give the photowall real polaroids).

When editing `style.css`, remember the dark theme at the bottom of the file. Anything hard-coded
as `rgba(61,46,30,…)` — a hairline, a sunken fill, a track — is invisible on the dark ground, so
use the `--hair` / `--hair-2` / `--hair-3` / `--sunken` / `--track` tokens instead. The hero room,
the phone mock and the mesh demo's little phones deliberately stay light in dark mode: they are
illustrations of lit objects, and they re-declare the light tokens locally rather than flipping.

## Deploying — GitHub Pages (the wired-up path)

[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) publishes this folder on every push
to `main` that touches `Site/` (and on demand via **Actions → Pages → Run workflow**). There is no
build step; the workflow runs the privacy-parity and no-third-party-asset checks, then uploads the
folder as-is.

One-time setup (owner):

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.** Until this is set, the
   deploy job fails.
2. **The repo must be public**, or the account needs GitHub Pro — GitHub Pages does not serve from
   a private repo on the free plan. (Going public is the plan anyway; see
   [`Docs/Verifiability.md`](../Docs/Verifiability.md) §7.)
3. **Custom domain (optional but intended):** Settings → Pages → Custom domain → `fernlet.com`.
   GitHub writes a `CNAME` file into the repo; keep it. Then at the registrar point the apex at
   GitHub's four A records (185.199.108–111.153) plus the AAAA records, or use `www` with a CNAME
   to `bowman-mw.github.io`. Tick **Enforce HTTPS** once the certificate is issued.
4. In App Store Connect, set:
   - Privacy Policy URL: `https://fernlet.com/privacy/`
   - Support URL: `https://fernlet.com/support/`

### What GitHub Pages cannot do

GitHub Pages serves fixed headers and **ignores `_headers`**. The CSP is therefore also declared as
a `<meta http-equiv="Content-Security-Policy">` in every page, so the "no external requests"
guarantee holds on either host. Three things have no meta equivalent and are simply absent on
Pages: `Strict-Transport-Security` (Pages sends its own HSTS when *Enforce HTTPS* is on),
`X-Frame-Options` (the CSP's `frame-ancestors` is meta-ignored too), and `X-Content-Type-Options`.
If those matter, use Cloudflare Pages below.

Note also that `404.html` links with absolute paths (`/style.css`, `/assets/…`, `/privacy/`), which is correct at
a domain root but **wrong under a project sub-path** like `bowman-mw.github.io/fernlet/`. Either use
the custom domain, or make those links relative before relying on the 404 page there.

## Deploying — Cloudflare Pages (alternative; serves the real headers)

One-time setup (needs a Cloudflare account + registrar access):

1. Create a free Cloudflare account → **Workers & Pages → Create → Pages**.
2. Either **connect the Git repo** (project root = `Site/`, no build command, output dir = `/`)
   or **Direct Upload** the `Site/` folder contents.
3. **Custom domains → add `fernlet.com`** (and `www.fernlet.com` if desired). Cloudflare will ask
   to manage DNS: at the registrar, change the nameservers to the two Cloudflare gives you.
   HTTPS is automatic once DNS propagates.
4. Set the same two App Store Connect URLs as above.

Subsequent deploys: push (Git-connected) or re-upload the folder (Direct Upload). Use one host or
the other — pointing both at `fernlet.com` is a DNS conflict, not a fallback.

## Reserved for the coach track (do NOT add yet)

- `/.well-known/apple-app-site-association` — needs the Apple Team ID + app IDs; added at coach
  P0 with `applinks` (and later `appclips`) entries. The `_headers` rule for it already exists,
  but it only takes effect on Cloudflare — GitHub Pages cannot set the content type on an
  extensionless file, so verify the AASA fetch works there before committing to that host.
- `/plan/` — the universal-link fallback page + static OG card metadata (coach P1; per-length
  variants only if the D11 prototype fails).
