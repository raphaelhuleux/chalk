# Mac: the tab row empties out when the Library is open

Reported by the owner 2026-08-18 17:15, two minutes after installing a fresh Catalyst build: "the tab alignment with the sidebar is broken again. We solved this many times but the bug keeps coming back."

Fixed the same day. Both causes measured on the owner's own running window, not inferred.

## Symptom

With the Library open, the Mac tab strip looked empty from the sidebar divider until the active tab, which floated roughly 200pt to its right.
The tabs were still there and still clickable. They just drew nothing.

## What it was not

It was not the strip's leading edge, which is where three earlier fixes landed and where this report pointed.
Measured on the live window through the accessibility API, the leading edge was exactly right:

| | window-relative x |
|---|---|
| Library / editor divider (`AXSplitter`) | 431 |
| first tab chip | 441 |

That is `dividerX + 10`, precisely what `pushStripLeadingInset` posts and `layoutInTitlebar` applies.
The strip started where it was supposed to start. What it drew there was blank.

## Root causes (two, independent, both landed the same day)

The same AX dump shows the real fault, in the chip sizes:

```
AXButton (49x34) '0_introduction.tex'   AXStaticText 2x5     <- label
AXButton (49x34) '1_model.tex'          AXStaticText 2x5
AXButton (265x37) '4_results_simple.tex' AXStaticText 204x17  <- the one readable tab
```

A 49pt chip is a chip with no label at all: 13pt padding either side, a 9pt gap and a 14pt slot is 49.
A 2x5 label is not a clipped label, it is a label drawn in a ~2.5pt font.

### 1. The preview tab's slant ate the font size

`stripFont(oblique:)` sheared the upright face through a font-descriptor matrix with the point size folded into it, and passed `size: 0`.
Under Catalyst that came back as a **2.5512pt** font: exactly `12 × 0.2126`, the slant constant.
The size was read from the shear term.

Logged from the running app:

```
CHALKDBG chip name=alpha.md preview=1 measured=0.000000 ptSize=2.551200
```

Every preview tab therefore drew an invisible smear, and since the chip measures itself from its label, it collapsed to bare padding.
The owner's window had one non-preview tab, which is why exactly one tab was readable.

This arrived in `78a27e9` (16:57 the same day), which made preview state show as slant at every tier.
Before it, preview state was shown by dimming and no font matrix was involved on the AppKit side.

Fix: the slant is now an `.obliqueness` text attribute, applied to the attributed string.
It shears at draw time and never touches the font, so there is no size to lose and the glyph advances stay those of the upright face, which is what chip widths are measured from.
The UIKit twin keeps its own matrix: it passes `size:` explicitly and UIKit honours it there. Two hosts, two mechanisms, one slant constant.

### 2. A crowded strip compressed inactive labels to nothing

Independently of the font, the AppKit strip left width distribution to constraint priorities.
Inactive labels carried `.defaultLow` compression resistance with no floor under them, so once the chips' natural widths exceeded the strip, every inactive label yielded its entire width.

Two changes in `27a7fd4` made that reachable in an ordinary window: `maxChipWidth` went 220 to 290, and the active label's compression resistance went to `.defaultHigh`, so the active chip now holds its full width and takes it out of its neighbours.
Six tabs at ~179pt natural need 1074pt; with the Library open the strip has ~813.

The escape hatch did not fire either. The chevron appeared only when `stack.frame.width < stack.fittingSize.width`, and collapsing the labels is what made the row fit, so `clipped` read false and the overflow menu never appeared to reach the tabs whose names had just vanished.

Fix: `ChalkKit.TabStripFit` plans the widths as arithmetic. Chips shrink toward a `minimumChipWidth` floor of 105pt (49pt of chrome plus 56pt of label, 7-8 mono characters), and whatever still does not fit is hidden and listed in the chevron menu. The active tab is never hidden and yields last.
A squeezed chip also sheds its `folder/` prefix before truncating, because tail truncation on the prefixed form spends the whole chip on the part every sibling shares: five tabs in one folder all reading `AuditFi…` is no better than five blank ones.

## Why this keeps coming back

Not bad luck, and not the same bug five times. Five structural reasons, each now with a guard:

1. **The strip is written twice.** `HeaderTabStrip` (UIKit) and `ChalkTabStrip` (AppKit, in the glue bundle) draw the same design from separately typed copies of the metrics, the palette and the policy. "Keep in sync by hand" is a comment, and comments do not fail builds.
2. **The AppKit copy has no tests and cannot have any.** The glue is a macOS bundle; `ChalkTests` is an iOS target and cannot link it. Every Mac chrome change is verified by eye or not at all.
3. **The layout decisions were emergent, not written.** Nobody chose "collapse the label to zero"; it fell out of a priority with no floor. There was no line of code to assert against even if a test could have reached it.
4. **The failure modes are silent.** A font matrix that loses its size raises nothing. A label compressed to zero raises nothing. A glue bundle that fails to load silently falls back to the UIKit strip (see the local-deploy note in `docs/` and the codesign trap).
5. **Verifying the Mac needs a build, an ad-hoc signature, a launch and a screenshot**, so "the tests pass" stands in for it. The screenshot audit did exist, but every `sidebar-*` state had one tab and every `tabs*` state had no sidebar, so the audit had no state that could show this.

## Guards added

| Guard | Catches |
|---|---|
| `ChalkKitTests/TabStripFitTests` (14 tests, `pnpm test:swift`) | a visible chip planned below the readable floor; tabs dropped without a chevron; the active tab dropped; tabs flickering as the window is resized |
| `ChalkTests/TabLabelFontTests` | the synthetic-oblique font losing its point size or its advances, on the UIKit side |
| `scripts/check-strip-parity.mjs` (`pnpm check:strip`, inside `pnpm typecheck`) | the 20 hand-mirrored tab metrics drifting between `StripMetrics` and `ChalkMetrics` |
| `CHALK_AUDIT_STATE=tabs6-sidebar` | the configuration no audit state produced: a crowded strip AND the Library open |
| `mac/project.yml` compiles `TabStripFit.swift` into the glue | the next shared policy being hand-copied instead of shared |

`TabStripFit.swift` is compiled into the glue target rather than linked, deliberately: the glue is a plugin bundle loaded inside an app that already links ChalkKit, and a second copy of the library in one process is a risk a bundle whose load failure is silent cannot take.

## Verification

- `swift test --package-path mac/ChalkKit`: `TabStripFitTests` 14/14.
- `ChalkTests/TabLabelFontTests` 4/4 on the iPad Pro 13-inch (M5) simulator.
- `node scripts/check-strip-parity.mjs` passes, and fails as intended when a metric is edited on one side only (checked by editing `maxChipWidth` to 220).
- Live Catalyst window, `CHALK_AUDIT_STATE=tabs6-sidebar`, measured through AX before and after:

| | before | after |
|---|---|---|
| inactive chip | 50x34, label 3x5 | 108x34, label 61x17 |
| active chip | 64x37, label 3x5 | 236x37, label 175x17 |
| first chip x vs divider | 442 vs 431 | 442 vs 431 (unchanged) |
| chevron | absent | present |

## Reproducing and measuring a live Catalyst window

The AX route is what turned this from guesswork into numbers, and it reads a window that is already running without touching it.

```bash
# Build, ad-hoc sign a COPY (never re-sign in place, see the deploy note), launch.
xcodebuild -project mac/Chalk.xcodeproj -scheme Chalk \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
ditto <built>/Chalk.app /tmp/ChalkSigned.app
codesign --force --deep --sign - /tmp/ChalkSigned.app
open -n --env CHALK_AUDIT_STATE=tabs6-sidebar -a /tmp/ChalkSigned.app --args -chalk.themePreference 2
```

An UNSIGNED direct-binary launch loads no glue bundle, so there is no AppKit strip to look at and the app silently shows the UIKit fallback. If the titlebar comes up empty, that is the reason.

Then dump the window's real frames (the script used here is in the session scratchpad; it is ~30 lines of `AXUIElementCopyAttributeValue` recursion over `kAXChildrenAttribute`, printing role, frame and window-relative origin).
Chip sizes and label sizes come straight out of it, which is how "the labels are 2x5" was established rather than assumed.

`screencapture -x -o -l <windowID>` captures a specific window even when occluded; window IDs come from `CGWindowListCopyWindowInfo`.

## Left open

- **The strip's regular face is not IBM Plex Mono.** `NSFont(name: "IBMPlexMono", …)` is nil: the bundled file's PostScript name is `IBMPlexMono-Regular` (the family is "IBM Plex Mono", with spaces). Inactive tabs therefore fall back to `.AppleSystemUIFontMonospaced-Regular` while the active tab, which asks for `IBMPlexMono-Medium`, gets the real face. The strip has been mixing two typefaces. `ChalkPalette.chalkMono` has the identical `default: name = "IBMPlexMono"` line, so the UIKit side is likely the same. Both are monospaced, so nothing breaks; it is a typography drift to decide on rather than a bug to rush.
