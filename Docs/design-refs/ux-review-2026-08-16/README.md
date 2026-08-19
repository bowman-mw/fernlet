# UI/UX review 2026-08-16 — evidence pack

The brief itself is [Docs/UI-UX-Review-2026-08-16.md](../../UI-UX-Review-2026-08-16.md).
[review.html](review.html) in this folder is the same 190 findings as a browsable page — open it in a
browser to filter by tab, severity, tier, "needs a mockup", Top 12, or systemic, with thumbnails that
open the full screenshot.

## What is here

| Folder | Contents |
| --- | --- |
| `shots/light/` | 46 screens: 5 tabs, 16 sheets, 8 onboarding steps, 13 Settings sub-screens — light, default type (iPhone 17) |
| `shots/dark/` | the same 46 in dark mode |
| `shots/ax/` | the same 46 at accessibility-extra-large Dynamic Type |
| `shots/manual/homefood/` | 118 hand-walked shots: Home (companion, customize/wardrobe/studio, all quick-log sheets, Trends, Milestones, First aid), Food (meal sheet + full log flow, Adjust, Recent/Scan/Import/Capture, recipe book/detail/edit/new, planner, shopping list, cooking mode) + `INDEX.md` |
| `shots/manual/movefriends/` | 87 shots: Move (goal/space setup, day details, plan/suggest/runner/log/edit/remove, progress photos, trainer export, coach paste), Friends (root, activities, roster, safety), fresh-install EMPTY states of all tabs + `INDEX.md` |
| `shots/manual/privatesettings/` | 106 shots: real lock gate, journal/editor/day detail, cycle/day detail/log period/intimacy, worry box, first aid (breathing/grounding), Settings hub + every sub-screen, app lock/duress, Privacy & Data incl. delete-everything alert + `INDEX.md` |

Each `INDEX.md` lists every file with its tap path, a **Not reached** list, and **Walker notes** —
first-hand friction observed while navigating. Screenshots here are half-resolution copies
(1311px tall); the review was performed against these.

## Using it with Claude Design

Pick a finding id from the brief, upload its **Current** screenshot(s) from `shots/`, and paste the
entry's *What's unclear or slow* + *Recommended change* as the prompt. 45 of the 190 entries need a
mockup; the other 145 are marked "Mockup needed: No" and can be implemented directly.

These files are **untracked** — decide deliberately before committing ~93 MB of PNGs (Git LFS or a
pruned subset would be the usual call).
