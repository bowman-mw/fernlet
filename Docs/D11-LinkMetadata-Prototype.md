# D11 Prototype — Do sender-supplied `LPLinkMetadata` titles survive into the sent iMessage bubble?

**Question (spec D11, [FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md) §3.3):**
when Coach hands a plan link to the share sheet with custom `LPLinkMetadata`
(title = "7/19–7/26 Workouts"), does the **sent** Messages bubble show that title — or does
Messages fetch the page and use the page's own metadata? Apple only documents the custom metadata
styling the *share-sheet header*, so this needs a real-device test.

Harness: [Fernlet/LinkMetadataPrototypeView.swift](../Fernlet/LinkMetadataPrototypeView.swift)
(DEBUG-only, not wired into any screen, delete after D11 is decided). The test URLs use
placeholder domains — `example.com` (plain stable title, no OG image), `apple.com` (rich OG
tags, like our future `/plan` pages), and the RFC 2606-reserved `.invalid` TLD (guaranteed
unresolvable) — chosen so each case distinguishes "custom metadata won" from "page fetch won."

## How to run (~30 min, two physical devices)

1. The harness file is already a target member (synced folder groups). Present it with a
   **temporary, uncommitted** line from any DEBUG screen, e.g. a
   `NavigationLink("D11 prototype") { LinkMetadataPrototypeView() }` in a Settings list.
2. Build to a **real iPhone** (the Simulator has no Messages/iMessage).
3. For each case A–G: **Share… → Messages**, send to a second device on a different Apple ID
   (your iPad or a willing friend — blue-bubble iMessage, not SMS).
4. Record the four observation columns below; screenshot each bubble.
5. **Fragment check (case E):** the recipient taps the link → Safari opens → confirm the address
   bar still ends with the full `#v1.…` fragment. (The page itself 404-ing is irrelevant; the
   address bar is the observation.)
6. Optional comparison: **Copy URL** and paste the bare link into Messages — that's the
   no-metadata path a coach would get without the share flow.

## Test matrix

| Case | URL | Custom metadata | What it isolates |
| --- | --- | --- | --- |
| A | `https://example.com/` | none | Baseline: fetch path works; bubble should say "Example Domain". |
| B | `https://example.com/` | title | **The core test** — custom title vs. fetched plain-page title. |
| C | `https://example.com/` | title + image | Does custom card artwork survive too? |
| D | `https://www.apple.com/` | title + image | Custom metadata vs. a page with rich OG tags (our real `/plan` pages will have OG tags). |
| E | `https://example.com/plan#v1.<~2 KB base64url>` | title | Realistic payload: bubble stays clean + fragment survives tap-through intact. |
| F | `https://example.com/plan/fernlet-d11-does-not-exist` | title | Fetch returns no useful metadata (404) — does the custom title render? |
| G | `https://fernlet-prototype.invalid/plan#v1.abc123` | title | Domain can never resolve — does a styled bubble send at all? |

## Results — fill in

| Case | Share-sheet header | Sender's sent bubble | Recipient's bubble | Tap-through / notes |
| --- | --- | --- | --- | --- |
| A |  |  |  |  |
| B |  |  |  |  |
| C |  |  |  |  |
| D |  |  |  |  |
| E |  |  |  | fragment intact: yes / no |
| F |  |  |  |  |
| G |  |  |  |  |

Tested on: iOS ______ (sender) / iOS ______ (recipient) · date ______

## Decision rule

- **PASS** — B, C, and E show the custom title in **both** the sender's and the recipient's
  bubbles → D11 resolved: per-plan titles are client-side and free. The static site is then only
  needed for AASA + the no-app fallback page + App Clip metadata — not for titles.
- **PARTIAL** — custom title on the sender's bubble but the recipient's device re-fetches and
  shows the page title → treat as FAIL (the recipient's view is the one that matters).
- **FAIL** — fall back to the spec's per-length static pages ("7-Day Workout Plan · Fernlet")
  with exact dates in the coach's message text (§3.3 option 2).

Interesting side-findings to note if they occur: if **G** still renders a styled bubble, bubble
presentation needs no live page at all (universal-link *opening* still needs the domain + AASA,
so D6 stands regardless); if **D** shows the page beating the custom metadata, our real `/plan`
pages' OG tags must be designed to lose gracefully (generic branding only).

## Caveats

- Green-bubble (SMS/RCS) recipients see the plain URL text regardless — the coach's summary line
  above the link carries the meaning there.
- Recipients can disable link previews (Settings → Messages), which also degrades to plain text.
- Re-run the E tap-through once the real domain + AASA exist to confirm universal-link opening
  preserves the fragment end-to-end (separate from the App Clip fragment prototype in F8).
