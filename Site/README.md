# fernlet.com — static site

The entire public web presence for Fernlet. **Static files only, forever** — the app's
"no servers anyone operates" rule applies here: no server-side code, no analytics, no cookies,
no external requests (enforced by the CSP in `_headers`). All pages are self-contained HTML
with inline CSS, system fonts, light/dark via `prefers-color-scheme` using the app's actual
theme hexes (`FernletThemeDefaults`).

## Contents

| Path | Purpose |
| --- | --- |
| `index.html` | Landing page. |
| `privacy/index.html` | The privacy policy — **generated from [`Docs/Privacy-Policy.md`](../Docs/Privacy-Policy.md)**, which stays the source of truth. When the policy changes, regenerate this page (and update `Fernlet/PrivacyPolicyView.swift`) so all three copies match. This URL goes in App Store Connect as the Privacy Policy URL. |
| `support/index.html` | Support/contact page — the ASC Support URL. |
| `404.html` | Not-found page (Cloudflare Pages picks it up automatically). |
| `_headers` | Cloudflare Pages headers: security baseline + the `application/json` content-type rule for the future AASA file. |

## Deploying (Cloudflare Pages, free tier)

One-time setup (owner does this — needs the Cloudflare account + registrar access):

1. Create a free Cloudflare account → **Workers & Pages → Create → Pages**.
2. Either **connect the Git repo** (project root = `Site/`, no build command, output dir = `/`)
   or **Direct Upload** the `Site/` folder contents.
3. **Custom domains → add `fernlet.com`** (and `www.fernlet.com` if desired). Cloudflare will ask
   to manage DNS: at the registrar, change the nameservers to the two Cloudflare gives you.
   HTTPS is automatic once DNS propagates.
4. In App Store Connect, set:
   - Privacy Policy URL: `https://fernlet.com/privacy/`
   - Support URL: `https://fernlet.com/support/`

Subsequent deploys: push (Git-connected) or re-upload the folder (Direct Upload).

## Reserved for the coach track (do NOT add yet)

- `/.well-known/apple-app-site-association` — needs the Apple Team ID + app IDs; added at coach
  P0 with `applinks` (and later `appclips`) entries. The `_headers` rule for it already exists.
- `/plan/` — the universal-link fallback page + static OG card metadata (coach P1; per-length
  variants only if the D11 prototype fails).
