#!/usr/bin/env python3
"""Mechanical half of the accessibility wall (Docs/Accessibility-Review-2026-08-22.md §4.5).

Scans shipping Swift for the accessibility invariants a line-level tokenizer can decide, and exits 1
on any violation not covered by Scripts/accessibility-allowlist.json. The enforced baseline is ZERO
for every rule; the allowlist is the only escape hatch and every entry states the invariant that
makes the exemption safe.

Three agents in the 2026-08-22 review independently proposed three separate walls
(DynamicTypeBoundaryTests, ColorContrastBoundaryTests, AccessibilitySemanticsBoundaryTests). This is
the one wall they collapse into, in the shape this repo already uses twice:
a scanner + a Swift-port boundary test (Tests/FernletTests/AccessibilityBoundaryTests) + one
allowlist JSON.

Usage:
    Scripts/accessibility-scan.py                 # scan the four shipping roots, human-readable
    Scripts/accessibility-scan.py --json          # same, machine-readable (one JSON object)
    Scripts/accessibility-scan.py <root> ...      # scan specific roots/files instead
    Scripts/accessibility-scan.py --allowlist a.json   # use this allowlist file instead

Checks (IDs match §4.5 and AccessibilityBoundaryTests):
    A1-COMBINE-LABEL   `.accessibilityElement(children: .combine)` followed, IN THE SAME MODIFIER
                       CHAIN, by `.accessibilityLabel(`. The label REPLACES everything `.combine`
                       gathered, so the pair is only correct when the label says strictly MORE than
                       the fragments it silences. Every legitimate pair is allowlisted with what it
                       adds.
    A2-RAWVALUE-SPOKEN `.rawValue` reaching anything VoiceOver SPEAKS — a spoken modifier
                       (label / value / hint / inputLabels / customContent / named action), UIKit's
                       property-assignment form, or the announcement channel. A rawValue is a frozen
                       English persistence-or-wire token; speaking one both leaks an implementation
                       detail and can never be translated. `.accessibilityIdentifier` is exempt by
                       design — an identifier IS a frozen token and should be derived from one.
    A3-HEADING-CANARY  SectionLabel / ScreenHeader / SheetHeader must each still ADD `.isHeader`.
                       Three one-line traits light up the VoiceOver Headings rotor across 124
                       headings app-wide (T1-1); losing one is silent and invisible.
    A4-FONT-SCALES     `.custom(_:size:)` without `relativeTo:` (and any `fixedSize:` font), which
                       is text that never responds to Larger Text. The baseline starts clean: all
                       11 type roles and every one-off already pass `relativeTo:`.
    A5-GRID-SCALES     `GridItem(.adaptive(minimum:))` / `GridItem(.fixed(…))` whose width is a bare
                       numeric literal, or a named width that this file never derives from a
                       `@ScaledMetric`. A fixed cell width truncates its label at accessibility text
                       sizes instead of reflowing.
    A6-INVERT-COLORS   `Image(uiImage:)` — a user photo or a rendered bitmap — with no
                       `.accessibilityIgnoresInvertColors` nearby. Smart Invert exists so a user can
                       darken UI while photographs stay photographs; an un-exempted bitmap is
                       colour-inverted into a negative (T2-10).
    A7-IGNORE-ON-BUTTON `.accessibilityElement(children: .ignore)` chained onto a `Button`. It mints
                       a SECOND, traitless element beside the real control, so the button stops
                       announcing as a button and its activation stops being discoverable (T2-29).
                       A label alone is the correct fix; `.ignore` is not.

Deliberately NOT here: "an accessibility label may not be a bare `String`". A grep cannot tell
`.accessibilityLabel(coverText)` (a String — a real defect) from `.accessibilityLabel(titleKey)`
(a LocalizedStringKey — correct). That rule lives in LocalizationBoundaryTests as a TYPE check on
the named members, and it is enforced there. One home per rule.

THE HONEST CEILING — what these rules still cannot catch, AFTER the 2026-08-23 hardening. Every
matcher below reads one file as text, so the wall is blind to anything that crosses a file, a
function call or a runtime branch:
  * A rawValue that reaches a label THROUGH A FUNCTION. `label(for:)` returning `mode.rawValue`,
    called as `.accessibilityLabel(label(for: mode))`, is invisible: A2's binding pass follows
    `let`/`var` declarations only, never a `func` return type or a parameter.
  * A rawValue that crosses a FILE. The binding pass is per-file by construction, so a
    `CompanionState.spokenName` computed in FernletDomainModel and spoken in HomeView is two files
    apart and neither half looks wrong alone.
  * Anything COMPUTED AT RUNTIME: a string built by `String(describing:)`, an enum switched into a
    dictionary, a value decoded from JSON, an AI-generated sentence. The wall reads source, and a
    frozen token can be assembled from pieces that are individually innocent.
  * A label that is PRESENT BUT WRONG. A1 asks whether a label replaces `.combine`'s fragments, not
    whether the replacement is good; A6 asks whether a bitmap opts out of Smart Invert, not whether
    the image has a label at all. "Says strictly more" is a human judgement and stays one.
  * MULTI-HOP DERIVATION past the fixed bounds. A5 follows a grid minimum back to a `@ScaledMetric`
    through at most three declaration hops; a fourth hop reports a false positive, and the fix is to
    bind the grid to the metric more directly rather than to widen the bound.
  * A7's ENCLOSURE TEST IS INDENTATION, not parsing. It finds the nearest `Button` opening at the
    same indent within a fixed lookback with no shallower line in between. Reformatted or
    machine-generated Swift, a `Button` produced by a helper (`iconButton { … }`), a
    `NavigationLink`, a `Menu` or a `.onTapGesture`-carrying container all read as "not a Button" —
    the rule's errors are FALSE NEGATIVES, deliberately, because a false positive on a container is
    the shape that gets a wall switched off.
  * A6 CANNOT TELL TWO ADJACENT IMAGES APART. One `.accessibilityIgnoresInvertColors` inside the
    window satisfies every `Image(uiImage:)` that opened within it.
  * Nothing here sees FOCUS ORDER, a missing custom action, an unhonored Reduce Motion, contrast as
    rendered, or how a screen actually sounds. Those are manual, forever, and the runtime half is
    `performAccessibilityAudit` in `UXScreenProbe`.

Allowlist entries (Scripts/accessibility-allowlist.json, a JSON array):
    {"rule": "A1-COMBINE-LABEL", "path": "…", "line_contains": "…", "reason": "…"}
`path` is repo-relative and required. `line_contains` (a substring of the offending code line)
narrows a file-wide entry; an entry without it covers every hit of that rule in that file. Unused
entries are reported so the allowlist cannot silently rot.
"""
import json
import os
import re
import sys

SHIPPING_ROOTS = ("FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension")

# ---------------------------------------------------------------------------------------------
# Fixed window bounds. Power of 10 rule 2: every scan below is bounded by one of these CONSTANTS,
# never by "keep looking until you find it". Each one is justified where it is used.
# ---------------------------------------------------------------------------------------------
A1_CALL_LINES = 4        # code lines joined so a wrapped `.accessibilityElement(…)` is one call
A1_CHAIN_STEPS = 4       # modifiers allowed between `.combine` and the label that replaces it
A2_WINDOW = 8            # code lines joined so a wrapped spoken-modifier argument list is one call
A2_BODY_LINES = 4        # code lines of a computed property's body read when binding identifiers
A5_WINDOW = 3            # code lines joined so a wrapped `GridItem(…)` is one call
A5_DERIVATION_LINES = 3  # code lines of a declaration read when deciding if it derives from a metric
A5_DERIVATION_PASSES = 3 # hops followed from a grid minimum back to a `@ScaledMetric`
A6_WINDOW = 12           # code lines after `Image(uiImage:)` searched for the Smart Invert opt-out
A7_LOOKBACK = 60         # code lines searched backwards for the `Button` a `.ignore` chains onto
ADD_TRAITS_SCAN_LIMIT = 32  # `accessibilityAddTraits(` calls inspected inside one canary's braces
WRAPPER_UNWRAPS = 3      # `Text(verbatim: …)`-style wrappers peeled off a spoken argument

# Modifiers whose argument VoiceOver reads out loud. `accessibilityIdentifier` is deliberately
# absent: it is a frozen test/automation token, never spoken, and deriving it from a rawValue is
# the CORRECT thing to do (12 sites do). `accessibilityAction` IS here: a NAMED action is read out
# by the Actions rotor, which is speech like any other.
SPOKEN_MODIFIERS = (
    "accessibilityLabel",
    "accessibilityValue",
    "accessibilityHint",
    "accessibilityInputLabels",
    "accessibilityCustomContent",
    "accessibilityAction",
)

# UIKit's property form of the same thing. `view.accessibilityLabel = mode.rawValue` has no call
# parentheses at all, so the modifier matcher is structurally blind to it — the two forms need two
# matchers, not one.
SPOKEN_PROPERTIES = (
    "accessibilityLabel",
    "accessibilityValue",
    "accessibilityHint",
    "accessibilityUserInputLabels",
    "accessibilityAttributedLabel",
    "accessibilityAttributedValue",
    "accessibilityAttributedHint",
)

# The announcement channel. This is where T1-10's original defect lived and where batch A3 shipped
# 24 announcer sites: a posted announcement is spoken IMMEDIATELY and never appears in any label, so
# a rawValue here is heard by every VoiceOver user and is invisible to every label-shaped check.
ANNOUNCEMENT_CALLS = (
    "AccessibilityNotification.Announcement(",
    "UIAccessibility.post(",
    "NSAccessibility.post(",
)

# The three shared components whose heading trait is the T1-1 regression canary:
# (repo-relative path, type name).
HEADING_CANARIES = (
    ("FernletKit/Sources/FernletUI/FernletPrimitives.swift", "SectionLabel"),
    ("FernletKit/Sources/FernletUI/FernletUIComponents.swift", "ScreenHeader"),
    ("FernletKit/Sources/FernletUI/SheetChrome.swift", "SheetHeader"),
)

NUMERIC_RE = re.compile(r"^\d+(?:\.\d+)?$")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")
CUSTOM_FONT_RE = re.compile(r"\.custom\(")
STRUCT_RE = re.compile(r"^\s*(?:public\s+|internal\s+|package\s+|private\s+|fileprivate\s+|final\s+)*"
                       r"(?:struct|class|enum)\s+([A-Za-z_]\w*)")
# Whitespace-tolerant everywhere Swift allows whitespace: `children:.combine` and `GridItem( .fixed(`
# are the same code as their spaced forms, and a wall that only knows one spelling is decorative.
ELEMENT_CALL = "accessibilityElement("
COMBINE_ARGS_RE = re.compile(r"^\s*children:\s*\.combine\s*$")
IGNORE_ELEMENT_RE = re.compile(r"accessibilityElement\(\s*children:\s*\.ignore\s*\)")
LABEL_STEP_RE = re.compile(r"^\.\s*accessibilityLabel\s*\(")
LABEL_ANYWHERE_RE = re.compile(r"\.\s*accessibilityLabel\s*\(")
GRID_COLUMN_RE = re.compile(r"GridItem\(\s*\.(?:adaptive\(\s*minimum:|fixed\()\s*([^,)]+)")
SCALED_METRIC_RE = re.compile(r"@ScaledMetric\b[\s\S]{0,160}?\bvar\s+([A-Za-z_]\w*)")
BINDING_RE = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^={]*)?(=(?!=)|\{)")
BOUND_ARG_RE = re.compile(r"\(\s*([A-Za-z_]\w*)\s*\)")
ASSIGN_RE = re.compile(r"\.(" + "|".join(SPOKEN_PROPERTIES) + r")\s*=(?!=)\s*(.+)$")
IMAGE_BITMAP_RE = re.compile(r"\bImage\(\s*uiImage:")
BUTTON_HEAD_RE = re.compile(r"\bButton\s*[({<]")
ADD_TRAITS_CALL = "accessibilityAddTraits("
INVERT_NEEDLE = "accessibilityIgnoresInvertColors"
WRAPPERS = ("Text(verbatim:", "Text(", "LocalizedStringKey(", "String(", "Optional(")

A1_DETAIL = ("a label in the same modifier chain as .combine REPLACES the fragments it gathered — "
             "allowlist it only if the label says strictly more than they do")
A6_DETAIL = ("Image(uiImage:) is a photograph or a rendered bitmap, and Smart Invert turns it into "
             "a colour negative. Add .accessibilityIgnoresInvertColors() (T2-10).")


def strip_code(line, st):
    """Return the code-only portion of `line`: string literals collapse to "" and comments are
    removed, so a rule never fires on a modifier name mentioned in a doc comment or inside a
    user-facing sentence. `st` = {"block": /* */ nesting depth, "mls": inside a multi-line string}.
    Approximate but line-faithful, and deliberately the same shape as power-of-10-scan.py's."""
    out = []
    i, n = 0, len(line)
    while i < n:
        if st["block"] > 0:
            j = line.find("*/", i)
            if j < 0:
                return "".join(out)
            st["block"] -= 1
            i = j + 2
            continue
        if st["mls"]:
            j = line.find('"""', i)
            if j < 0:
                return "".join(out)
            st["mls"] = False
            i = j + 3
            continue
        ch = line[i]
        if line.startswith('"""', i):
            st["mls"] = True
            i += 3
            continue
        if line.startswith("//", i):
            return "".join(out)
        if line.startswith("/*", i):
            st["block"] += 1
            i += 2
            continue
        if ch == '"':
            # Collapse the literal's TEXT but keep its `\\(…)` interpolations, which are code and
            # are where the A2 defect actually lives: `.accessibilityLabel("Fernlet companion,
            # \\(state.rawValue)")` is a spoken rawValue, and erasing the whole literal would
            # make the rule blind to the one shape the review found in the shipping app.
            i += 1
            out.append('""')
            while i < n:
                if line[i] == "\\" and i + 1 < n and line[i + 1] == "(":
                    depth, j = 0, i + 1
                    while j < n:
                        if line[j] == "(":
                            depth += 1
                        elif line[j] == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        j += 1
                    out.append(line[i + 1:min(j + 1, n)])
                    i = j + 1
                    continue
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def code_lines(lines):
    """[(1-based line number, code-only text, raw source text)] for every line carrying code.

    Detection runs on the code-only text (so a rule never fires on a modifier named inside a doc
    comment or a user-facing sentence), but every hit REPORTS the raw line. That split is
    load-bearing for the allowlist: string literals collapse to `""` in the code-only form, which
    would make `.accessibilityLabel("")` the text of every literal-label hit in a file and leave
    `line_contains` unable to tell three deliberate sites apart."""
    st = {"block": 0, "mls": False}
    result = []
    for idx, raw in enumerate(lines, start=1):
        code = strip_code(raw, st)
        if code.strip():
            result.append((idx, code, raw))
    return result


def call_bounds(text, start):
    """(index of the '(' of the call at or after `start`, index of its matching ')').

    Bounded by the length of `text`: the loop can only advance, so it terminates on every input,
    including unbalanced source (which reports the remainder)."""
    open_idx = text.find("(", start)
    if open_idx < 0:
        return None
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return (open_idx, i)
    return (open_idx, len(text))


def call_span(text, start):
    """The balanced-paren argument text of the call whose '(' is at or after `start`."""
    bounds = call_bounds(text, start)
    return "" if bounds is None else text[bounds[0] + 1:bounds[1]]


def joined(coded, start, count):
    """(joined code text, per-line start offsets) for a FIXED window of `count` code lines.

    Comment-only and blank lines are already gone from `coded`, so the window measures MODIFIERS,
    not source lines — a ten-line explanatory comment between two modifiers costs nothing."""
    parts, starts, off = [], [], 0
    for _lineno, code, _raw in coded[start:start + count]:
        starts.append(off)
        parts.append(code)
        off += len(code) + 1
    return " ".join(parts), starts


def line_of(starts, pos):
    """The window-relative index of the code line containing character offset `pos`."""
    found = 0
    for idx, off in enumerate(starts):
        if off <= pos:
            found = idx
    return found


def indent_of(code):
    """Leading-whitespace width of a code-only line."""
    return len(code) - len(code.lstrip())


def hit(rule, path, line, text, detail):
    return {"rule": rule, "path": path, "line": line, "text": text.strip()[:160], "detail": detail}


# ---------------------------------------------------------------------------------------------
# A1
# ---------------------------------------------------------------------------------------------

def chain_label(coded, end_index, leftover):
    """Index into `coded` of the `.accessibilityLabel(` continuing the SAME chain, or None.

    The semantics being enforced is "anywhere later in this modifier chain", not "the very next
    line": `.combine` / `.padding(4)` / `.accessibilityLabel(…)` silences the fragments exactly as
    the adjacent pair does. The chain is walked one modifier at a time and stops at the first line
    that does not begin with `.`, which is what actually ends a SwiftUI chain — so the bound is not
    guessing at scope, it is a ceiling on how far a legitimate chain is allowed to run before the
    wall stops looking. A1_CHAIN_STEPS = 4 is that ceiling: it clears the three-modifier
    `.padding`/`.background`/`.contentShape` runs this codebase actually writes, and leaves the
    rule reporting the LABEL's line so `line_contains` can still name a specific literal."""
    tail = leftover.strip()
    if tail.startswith("."):
        if LABEL_ANYWHERE_RE.search(tail):
            return end_index
    elif tail:
        return None
    for j in range(end_index + 1, min(end_index + 1 + A1_CHAIN_STEPS, len(coded))):
        step = coded[j][1].strip()
        if not step.startswith("."):
            return None
        if LABEL_STEP_RE.match(step):
            return j
    return None


def scan_combine_label(rel, coded):
    """A1: `.combine` followed, in the same modifier chain, by `.accessibilityLabel(`."""
    hits = []
    for i, (_lineno, code, _raw) in enumerate(coded):
        if ELEMENT_CALL not in code:
            continue
        text, starts = joined(coded, i, A1_CALL_LINES)
        bounds = call_bounds(text, text.find(ELEMENT_CALL))
        if bounds is None or not COMBINE_ARGS_RE.match(text[bounds[0] + 1:bounds[1]]):
            continue
        rel_line = line_of(starts, bounds[1])
        next_off = starts[rel_line + 1] if rel_line + 1 < len(starts) else len(text) + 1
        end_index = i + rel_line
        found = chain_label(coded, end_index, text[bounds[1] + 1:max(bounds[1] + 1, next_off - 1)])
        if found is not None:
            hits.append(hit("A1-COMBINE-LABEL", rel, coded[found][0], coded[found][2], A1_DETAIL))
    return hits


# ---------------------------------------------------------------------------------------------
# A2
# ---------------------------------------------------------------------------------------------

def rawvalue_bound_names(coded):
    """Identifiers in THIS file bound to an expression containing `.rawValue`.

    Two shapes, both bounded: `let/var X = …rawValue…` read on its own line, and a computed
    `var X: T { …rawValue… }` read across A2_BODY_LINES code lines. Ceiling, stated plainly: it
    does not follow a rawValue through a `func`, through a parameter, or across a file — those
    stay invisible, and they are named in the module docstring."""
    names = set()
    for i, (_lineno, code, _raw) in enumerate(coded):
        m = BINDING_RE.search(code)
        if m is None:
            continue
        if m.group(2) == "=":
            if ".rawValue" in code[m.end():]:
                names.add(m.group(1))
            continue
        body, _starts = joined(coded, i, A2_BODY_LINES)
        if ".rawValue" in body[m.end():]:
            names.add(m.group(1))
    return names


def speaks_bound_name(args, bound):
    """Whether `args` is (or interpolates) one of the rawValue-bound identifiers."""
    core = args.strip()
    for _ in range(WRAPPER_UNWRAPS):
        peeled = core
        for wrapper in WRAPPERS:
            if core.startswith(wrapper) and core.endswith(")"):
                peeled = core[len(wrapper):-1].strip()
                break
        if peeled == core:
            break
        core = peeled
    if core in bound:
        return True
    return any(name in bound for name in BOUND_ARG_RE.findall(args))


def spoken_call_hits(rel, lineno, raw, code, window, bound):
    """A2's CALL forms: a spoken SwiftUI modifier, or a posted announcement."""
    out = []
    for modifier in SPOKEN_MODIFIERS:
        token = "." + modifier + "("
        if token not in code:
            continue
        args = call_span(window, window.find(token))
        if ".rawValue" in args or speaks_bound_name(args, bound):
            out.append(hit("A2-RAWVALUE-SPOKEN", rel, lineno, raw,
                           f".{modifier} is SPOKEN; a rawValue is a frozen English "
                           f"persistence/wire token. Use the type's display fork."))
    for token in ANNOUNCEMENT_CALLS:
        if token not in code:
            continue
        args = call_span(window, window.find(token))
        if ".rawValue" in args or speaks_bound_name(args, bound):
            out.append(hit("A2-RAWVALUE-SPOKEN", rel, lineno, raw,
                           f"{token}…) is spoken IMMEDIATELY and appears in no label, so a frozen "
                           f"English token here is heard by every VoiceOver user."))
    return out


def spoken_assignment_hits(rel, lineno, raw, code, bound):
    """A2's UIKit PROPERTY form: `view.accessibilityLabel = mode.rawValue`, which has no call
    parentheses at all and is therefore invisible to the modifier matcher."""
    m = ASSIGN_RE.search(code)
    if m is None:
        return []
    if ".rawValue" not in m.group(2) and not speaks_bound_name(m.group(2), bound):
        return []
    return [hit("A2-RAWVALUE-SPOKEN", rel, lineno, raw,
                f"UIKit's .{m.group(1)} property is SPOKEN; a rawValue is a frozen English "
                f"persistence/wire token. Use the type's display fork.")]


def scan_rawvalue_spoken(rel, coded):
    """A2: `.rawValue` reaching anything VoiceOver speaks.

    The join window is fixed at A2_WINDOW code lines (Power of 10 rule 2 — no growing scan). Eight
    rather than the original four because a deeply wrapped argument list —
    `.accessibilityHint(\\n Text(\\n verbatim: String(\\n describing: Optional(\\n x.rawValue`
    — is five lines deep before it says anything, and four lines silently exempted it."""
    bound = rawvalue_bound_names(coded)
    hits = []
    for i, (lineno, code, raw) in enumerate(coded):
        window, _starts = joined(coded, i, A2_WINDOW)
        hits.extend(spoken_call_hits(rel, lineno, raw, code, window, bound))
        hits.extend(spoken_assignment_hits(rel, lineno, raw, code, bound))
    return hits


# ---------------------------------------------------------------------------------------------
# A4 / A5 / A6 / A7
# ---------------------------------------------------------------------------------------------

def scan_font_scales(rel, coded):
    """A4: a `.custom` font without `relativeTo:` — text that ignores Larger Text.

    A font `.custom(_:size:)` always carries `size:` or `fixedSize:`, which is what separates it
    from unrelated `.custom(label:group:)`-style factory methods elsewhere in the tree."""
    hits = []
    for i, (lineno, code, raw) in enumerate(coded):
        for _m in CUSTOM_FONT_RE.finditer(code):
            window, _starts = joined(coded, i, 3)
            args = call_span(window, window.find(".custom("))
            if "fixedSize:" in args:
                hits.append(hit("A4-FONT-SCALES", rel, lineno, raw,
                                "fixedSize: pins the point size — the text never responds to Larger Text"))
            elif "size:" in args and "relativeTo:" not in args:
                hits.append(hit("A4-FONT-SCALES", rel, lineno, raw,
                                "Font.custom(_:size:) without relativeTo: never scales with Dynamic Type"))
            break   # one report per line is enough; the fix is the same edit
    return hits


def scaling_names(whole, coded):
    """Identifiers in this file that actually carry Dynamic Type scaling.

    Seeded with every `@ScaledMetric … var X`, then closed over declarations that READ one of those
    — `private var itemTileMinimum: CGFloat { min(scaledItemTileMinimum, 300) }` is the shipping
    shape, and it is correct. The closure runs A5_DERIVATION_PASSES fixed passes, never to a
    fixpoint: a chain deeper than three hops is reported, and the fix is to bind the grid to the
    metric more directly rather than to widen the bound.

    This replaces the previous test, which was "the FILE contains the string @ScaledMetric
    anywhere". That version let one unrelated metric launder every named minimum in a 3000-line
    view file, which is exactly the shape an evasion takes."""
    names = set(SCALED_METRIC_RE.findall(whole))
    declarations = {}
    for i, (_lineno, code, _raw) in enumerate(coded):
        m = BINDING_RE.search(code)
        if m is None:
            continue
        body, _starts = joined(coded, i, A5_DERIVATION_LINES)
        declarations[m.group(1)] = body[m.end():]
    for _ in range(A5_DERIVATION_PASSES):
        grew = False
        for name, body in declarations.items():
            if name in names:
                continue
            if any(token in names for token in IDENT_RE.findall(body)):
                names.add(name)
                grew = True
        if not grew:
            break
    return names


def scan_grid_scales(rel, coded, whole):
    """A5: a grid column width that cannot grow with the text it holds.

    Covers `.adaptive(minimum:)` AND `.fixed(_:)` — a fixed column is the same defect with the
    reflow removed as well. The `GridItem(` call is read across a FIXED A5_WINDOW-line join so a
    wrapped `GridItem(\\n .adaptive(minimum: 80)\\n)` is still one call, and a match is reported
    only when the `GridItem(` token itself began on the window's first line, which is what keeps
    overlapping windows from reporting the same site twice."""
    scaling = scaling_names(whole, coded)
    hits = []
    for i, (lineno, code, raw) in enumerate(coded):
        if "GridItem(" not in code:
            continue
        text, starts = joined(coded, i, A5_WINDOW)
        for m in GRID_COLUMN_RE.finditer(text):
            if line_of(starts, m.start()) != 0:
                continue
            arg = m.group(1).strip()
            if NUMERIC_RE.match(arg):
                hits.append(hit("A5-GRID-SCALES", rel, lineno, raw,
                                f"a GridItem width of {arg} is a fixed point value — at accessibility "
                                f"text sizes the cell cannot grow and its label truncates. Bind it to "
                                f"an @ScaledMetric(relativeTo:)."))
            elif not any(token in scaling for token in IDENT_RE.findall(arg)):
                hits.append(hit("A5-GRID-SCALES", rel, lineno, raw,
                                f"the GridItem width '{arg}' names nothing this file derives from a "
                                f"@ScaledMetric, so nothing scales the cell with Dynamic Type."))
    return hits


def scan_invert_colors(rel, coded):
    """A6: a rendered-bitmap `Image(uiImage:)` that never opts out of Smart Invert.

    Smart Invert exists so a user can darken the UI while photographs stay photographs; without
    `.accessibilityIgnoresInvertColors()` a meal photo, a progress photo, a QR code or a scanned
    still is rendered as a colour negative (T2-10). A6_WINDOW = 12 code lines: the widest
    legitimate gap in the tree is 8 (BarcodeScanView.swift:287 → :297, a
    resizable/scaledToFill/frame/clipped run), and 12 leaves headroom for a few more modifiers.
    Known false negative, stated rather than hidden: two `Image(uiImage:)` inside one window are
    satisfied by a single opt-out."""
    hits = []
    for i, (lineno, code, raw) in enumerate(coded):
        if not IMAGE_BITMAP_RE.search(code):
            continue
        window, _starts = joined(coded, i, A6_WINDOW)
        if INVERT_NEEDLE in window:
            continue
        hits.append(hit("A6-INVERT-COLORS", rel, lineno, raw, A6_DETAIL))
    return hits


def button_head_line(coded, index, pos):
    """The source line of the `Button` this `.ignore` is chained onto, or None.

    HONEST HEURISTIC, and its direction is deliberate. A grep cannot parse SwiftUI, so "is this
    modifier on a Button?" is decided by layout: the nearest `Button` opening at the SAME indent,
    within A7_LOOKBACK code lines, with no SHALLOWER line in between (a shallower line means the
    walk has left the view expression the modifier belongs to). It errs towards FALSE NEGATIVES —
    a `Button` made by a helper, a `NavigationLink`, a `Menu`, a `.onTapGesture` container, or
    reformatted source all read as "not a button" — because a false positive on a plain container
    is the shape that gets a wall switched off. On this tree it separates the four Button sites
    from the fifteen container sites with no misses in either direction."""
    code = coded[index][1]
    if BUTTON_HEAD_RE.search(code[:pos]):
        return coded[index][0]
    want = indent_of(code)
    for j in range(index - 1, max(-1, index - 1 - A7_LOOKBACK), -1):
        step = coded[j][1]
        here = indent_of(step)
        if here < want:
            return None
        if here == want and BUTTON_HEAD_RE.search(step):
            return coded[j][0]
    return None


def scan_ignore_on_button(rel, coded):
    """A7: `.accessibilityElement(children: .ignore)` chained onto a `Button` (T2-29).

    `.ignore` on a control mints a SECOND, traitless accessibility element beside the real one: the
    button stops announcing as a button, VoiceOver stops offering "double tap to activate", and the
    Buttons rotor loses it. The correct fix is `.accessibilityLabel` alone — the label already
    replaces the subtree's fragments on a control, without minting anything."""
    hits = []
    for i, (lineno, code, raw) in enumerate(coded):
        m = IGNORE_ELEMENT_RE.search(code)
        if m is None:
            continue
        head = button_head_line(coded, i, m.start())
        if head is None:
            continue
        hits.append(hit("A7-IGNORE-ON-BUTTON", rel, lineno, raw,
                        f"the Button opening at line {head} already exposes itself as one element; "
                        f"children: .ignore mints a traitless twin beside it and the control stops "
                        f"announcing as a button. Use .accessibilityLabel alone."))
    return hits


# ---------------------------------------------------------------------------------------------
# A3
# ---------------------------------------------------------------------------------------------

def adds_heading_trait(body):
    """Whether `body` ADDS `.isHeader`, rather than merely mentioning it.

    A bare `.isHeader` substring is not evidence: `.accessibilityRemoveTraits(.isHeader)` contains
    it and does the exact opposite, so the old substring canary would have stayed green through the
    very regression it exists to catch. The trait must appear inside an `accessibilityAddTraits(`
    argument list."""
    pos = 0
    for _ in range(ADD_TRAITS_SCAN_LIMIT):
        pos = body.find(ADD_TRAITS_CALL, pos)
        if pos < 0:
            return False
        if ".isHeader" in call_span(body, pos):
            return True
        pos += len(ADD_TRAITS_CALL)
    return False


def canary_body(coded, type_name):
    """(body text, last line number) of `type_name`'s own brace span, or None."""
    start = None
    for idx, (_lineno, code, _raw) in enumerate(coded):
        m = STRUCT_RE.match(code)
        if m and m.group(1) == type_name:
            start = idx
            break
    if start is None:
        return None
    depth, body, end = 0, [], coded[start][0]
    for idx in range(start, len(coded)):
        lineno, code, _raw = coded[idx]
        body.append(code)
        depth += code.count("{") - code.count("}")
        end = lineno
        if depth <= 0 and idx > start:
            break
    return (" ".join(body), end)


def scan_heading_canaries(repo):
    """A3: the three shared heading components must still ADD `.isHeader`.

    Scoped to each type's own brace span, so moving the trait onto a neighbouring view in the same
    file does not keep the check green."""
    hits = []
    for rel, type_name in HEADING_CANARIES:
        path = os.path.join(repo, rel)
        if not os.path.exists(path):
            hits.append(hit("A3-HEADING-CANARY", rel, 0, type_name, "file is missing"))
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            coded = code_lines(f.readlines())
        found = canary_body(coded, type_name)
        if found is None:
            hits.append(hit("A3-HEADING-CANARY", rel, 0, type_name,
                            f"{type_name} no longer exists in this file — the T1-1 canary cannot be checked"))
            continue
        body, end = found
        if not adds_heading_trait(body):
            hits.append(hit("A3-HEADING-CANARY", rel, end, type_name,
                            f"{type_name} no longer ADDS .isHeader via accessibilityAddTraits( — the "
                            f"VoiceOver Headings rotor went dark across every one of its call sites, "
                            f"silently. A .accessibilityRemoveTraits(.isHeader) does not count."))
    return hits


# ---------------------------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------------------------

def iter_swift(roots):
    for root in roots:
        if os.path.isfile(root) and root.endswith(".swift"):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".build", "build", "DerivedData")]
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def load_allowlist(repo, override):
    path = override or os.path.join(repo, "Scripts", "accessibility-allowlist.json")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        entries = json.load(f)
    for e in entries:
        e["_used"] = 0
    return entries


def allowed(h, allowlist):
    for e in allowlist:
        if e["rule"] != h["rule"] or e["path"] != h["path"]:
            continue
        if "line_contains" in e and e["line_contains"] not in h["text"]:
            continue
        e["_used"] += 1
        return True
    return False


def scan_file(path, rel):
    """Every per-file rule, run over one Swift file."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    coded = code_lines(lines)
    whole = "".join(lines)
    hits = []
    hits.extend(scan_combine_label(rel, coded))
    hits.extend(scan_rawvalue_spoken(rel, coded))
    hits.extend(scan_font_scales(rel, coded))
    hits.extend(scan_grid_scales(rel, coded, whole))
    hits.extend(scan_invert_colors(rel, coded))
    hits.extend(scan_ignore_on_button(rel, coded))
    return hits


def report(violations, unused, n_files, allowed_hits):
    by_rule = {}
    for v in violations:
        by_rule.setdefault(v["rule"], []).append(v)
    for rule in sorted(by_rule):
        print(f"== {rule}: {len(by_rule[rule])} ==")
        for v in by_rule[rule]:
            print(f"{v['path']}:{v['line']}: {v['text']}\n    -> {v['detail']}")
    for e in unused:
        print(f"UNUSED ALLOWLIST ENTRY: {json.dumps({k: v for k, v in e.items() if k != '_used'})}")
    print(f"\nfiles scanned: {n_files}; violations: {len(violations)}; "
          f"allowlisted hits: {allowed_hits}", file=sys.stderr)


def main(argv):
    as_json = "--json" in argv
    override = None
    if "--allowlist" in argv:
        i = argv.index("--allowlist")
        override = argv[i + 1] if i + 1 < len(argv) else sys.exit("--allowlist needs a path")
        argv = argv[:i] + argv[i + 2:]
    args = [a for a in argv if not a.startswith("--")]
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    roots = args or [os.path.join(repo, r) for r in SHIPPING_ROOTS]
    allowlist = load_allowlist(repo, override)

    hits, n_files = [], 0
    for path in iter_swift(roots):
        n_files += 1
        hits.extend(scan_file(path, os.path.relpath(path, repo)))
    # A3 is whole-repo rather than per-file: it asserts something EXISTS, so it must run even when
    # the file it names was not in the scanned set (otherwise deleting the file passes the wall).
    if not args:
        hits.extend(scan_heading_canaries(repo))

    violations = [h for h in hits if not allowed(h, allowlist)]
    unused = [e for e in allowlist if e["_used"] == 0]
    allowed_hits = len(hits) - len(violations)

    if as_json:
        print(json.dumps({
            "files": n_files,
            "violations": violations,
            "allowed": allowed_hits,
            "unused_allowlist": [{k: v for k, v in e.items() if k != "_used"} for e in unused],
        }, indent=1))
    else:
        report(violations, unused, n_files, allowed_hits)

    if n_files == 0:
        print("no Swift files scanned — refusing to pass vacuously", file=sys.stderr)
    sys.exit(1 if (violations or unused or n_files == 0) else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
