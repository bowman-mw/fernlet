# Exercise demonstration media (drop folder)

This folder holds the exercise demonstrations licensed from Gym Visual (gymvisual.com): animated
GIFs and still illustrations, male and female. Only this README and the `.gitignore` beside it are
part of the repository.

## Never commit these files

The Gym Visual licence (N-CRFL) forbids redistribution, and this repository is public under
Apache-2.0. A media file committed here, even once, is redistributed. So:

- The `.gitignore` ignores everything in this folder except itself and this README. Never
  `git add -f` a file from here, and never move the media anywhere else in the tree.
- The licence also forbids AI use. Never give these files to an AI tool. In the app they are
  only drawn in the exercise how-to sheet; no prompt builder or on-device model call reads them or
  the code that finds them (`ExerciseDemonstrationTests` fails if one does).
- The media are not covered by the repository's licence (see `NOTICE`).

## Naming

Name each file by its Gym Visual ID, exactly as the mapping spells it, leading zeros included:

| Kind | File name | Example |
| --- | --- | --- |
| Animated GIF | `<GymVisualID>.gif` | `002513.gif` |
| Illustration | `<GymVisualID>.png` or `<GymVisualID>.jpg` | `0025.png` |

The IDs are in `App/Fernlet/ExerciseDemonstrations.json`, keyed by the exercise's catalog name,
with `gifMale`, `gifFemale`, `illustrationMale` and `illustrationFemale` (null where Gym Visual has
no such version). GIF IDs are 6 digits (six are 7); illustration IDs are 4 digits (six are 5).

Extensions are lowercase. Put the files directly in this folder, not in a subfolder. Any other
file name is ignored by the app and fails `ExerciseDemonstrationTests`, which checks what sits here,
as does a file whose ID no exercise's mapping names (a mistyped ID).

## How the files get into the app

`App/Fernlet` is a synchronized folder in the Xcode project, so whatever is in this folder at build
time is copied into the app bundle, at its root, with no project edit. The project excludes this
README and the `.gitignore` from the app target, so an empty folder builds cleanly and ships
nothing from here. Rebuild after adding or removing files.

Release and Xcode Cloud builds do not fetch the media yet: a build from a clean clone ships with
placeholders everywhere.

## What shows, and when a file is missing

The how-to sheet picks, for the exercise and the sex in the user's profile:

1. that sex's GIF, playing in a loop;
2. the other sex's GIF;
3. an illustration, that sex's first, then the other's;
4. a placeholder: a blank cream square, the same size as the media. It shows the exercise's equipment glyph
   over a framed text box with its name, and is hidden from VoiceOver. Each licensed file that lands here
   replaces its exercise's square on the next build.

With Reduce Motion on, an illustration comes first; if only a GIF is present, its first frame shows,
held still. Only files actually in the bundle count, so a missing file simply falls through to the
next choice, and the app builds and runs with this folder empty.

## Check these by eye before buying

The mapping flagged these as variants or differently titled items. Look at Gym Visual's preview,
and skip or swap any that would teach the wrong form (with its paired illustration):

| Gym Visual ID | Exercise |
| --- | --- |
| `029213` | Dumbbell row |
| `037813` | Rear delt fly |
| `041013` | Bulgarian split squat (male) |
| `157613` | Lying hamstring stretch (male) |
| `209913` | Figure-four stretch |
| `430113` | Cross-body shoulder stretch (female) |
| `068413` | Treadmill run (male) |
| `394413` | Alternating knee tuck (male; Gym Visual's "Seated Alternate Crunch", reclined on a bench) |
| `600213`, `600313` | Tucked toe tap ("Lying Toe Tap": check the knees stay bent at 90°) |
| `086213`, `120813` | Cable woodchopper ("Cable Twist (up-down)") |
| `022813`, `088013` | Cable glute kickback ("Cable Standing Hip Extension") |
| `232413` | Cable pull-through (female; a straight-legged rope version) |

A swapped item needs its new ID in `ExerciseDemonstrations.json` too.
