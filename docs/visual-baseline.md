# Visual baseline: Commit and Log at 1642×1015

Reference application: **Rebased 1.1.13** (`io.github.detachhead.rebased`), the
fork Arbor is modelled on. Both applications open the same deterministic
repository (`scripts/make-ui-fixture.sh`) with the window dragged to exactly
1642×1015, so the captures are comparable pixel for pixel.

| Screen | Arbor | Rebased |
| --- | --- | --- |
| Commit | `docs/images/baseline/arbor-commit.png` | `docs/images/baseline/rebased-commit.png` |
| Log | `docs/images/baseline/arbor-log.png` | `docs/images/baseline/rebased-log.png` |

Status: the Commit layout difference (C1/C2) is fixed, and so is the left
column width; the remaining rows are open.

Recapture with:

```sh
./scripts/visual-baseline.sh            # Arbor only
./scripts/visual-baseline.sh --reference # also resize and capture Rebased
```

The reference capture needs Rebased open with the fixture project; the script
reuses that window and restores its Commit tool window afterwards.

## Screen composition

Rebased keeps three surfaces on screen at once and lets the user hide one:
Commit tool window (left top), Project tree (left bottom), Log tool window
(center) with two detail panes on the right.

| | Arbor | Rebased |
| --- | --- | --- |
| Left column width | 628 pt (38%), measured | 628 pt (38%) |
| Commit mode | Commit panel + project tree, Log in the centre | Commit panel **+** project tree **+** log |
| Log mode | Project tree + Log + commit detail | Project tree + Log + two detail panes |
| Tool windows | Commit and Log are both on screen; Operations replaces the editor | independent; any combination |

## Commit screen

| # | Difference | Arbor | Rebased |
| --- | --- | --- | --- |
| ~~C1~~ | ~~Window use~~ | Fixed: the Log editor fills the centre in Commit mode | The same area carries the Log and the project tree |
| ~~C2~~ | ~~Left column content~~ | Fixed: Commit/Stash tabs with the Project tree below them, expanded by default | Commit/Stash tabs, then the Project tree below them |
| C2b | Tool-window title | An extra `Commit` row above the Commit/Stash tabs | No such row; the tab strip is the title |
| ~~C2c~~ | ~~Left column width~~ | Fixed: 628 pt — 52 pt rail + 564 pt panel + 12 pt divider, measured from the accessibility tree, matching the reference exactly | 628 pt |
| C2d | Left column split | Commit 626 pt / Project 441 pt | Commit 510 pt / Project 505 pt |
| C3 | Change list header | Changelist row `● Default 5` | `Changes 2 files` with a select-all checkbox |
| C4 | Ignored files | `Ignored Files 2 files` expanded by default, taking two rows among real changes | Not shown |
| C5 | Untracked files | Listed inside `Unstaged Files` | Separate collapsed `Unversioned Files 5 files` group with a tri-state checkbox |
| C6 | Commit footer | `Template`, `Skip hooks`, `Commit`, `Commit and …` | `Commit`, `Commit and Push…`, options behind the gear |
| C7 | Change counters | none | `2 modified` beside the Amend row |
| C8 | Row status | coloured square badge `M`/`U`/`I` | coloured letter, no badge |
| C9 | Tree icons | text only | file-type icons and a `M+` status chip |

## Log screen

| # | Difference | Arbor | Rebased |
| --- | --- | --- | --- |
| L1 | Filter bar | Always-visible fields (`Text or hash`, `Paths`, `User`, `Since`, `Until`) overflow the pane: the `Branch` control is clipped at the pane edge | One row that fits: text field, `Cc`, `Branch ⌄`, `User ⌄`, `Date ⌄`, `Paths ⌄` |
| L2 | Log columns | Commit message + ref badges | Commit, Author, Date, ref badges |
| L3 | Graph | 2 px blue line, 8 pt filled nodes | 1 px line, hollow nodes |
| L4 | Right pane | Commit detail is auto-populated for the selected row, and the Changes panel with the Side-by-side/Unified toggle sits below it | Both right panes stay at their empty states until the user selects a commit |
| L5 | Project tree | text rows, no status decoration | file-type icons and `M+`/`M` chips |
| L6 | Toolbar | Update, Commit, Push, Fetch, More Git Actions, Refresh, Language, Search | two icons, notifications |
| L7 | Status bar | branch, ahead/behind, Git, Operation Log, change count, project state, path, HEAD | `PsiDirectory:…` / `PsiBinaryFile:Log` |
| L8 | Notification | none | “IDE project settings can be added to Git” banner |

## Priority

1. ~~**C1/C2 — Commit mode wastes the window.**~~ Fixed: the Log loads and
   stays on screen in Commit mode, and the Project tool window starts expanded
   below the Commit surface, matching the reference.
2. **L1 — the Log filter bar does not fit.** The `Branch` control is clipped at
   1642×1015. The reference fits the same controls by folding `User`, `Date`
   and `Paths` into dropdowns instead of always-visible fields.
3. **C4 — ignored files are on by default.** They occupy the change list next
   to real work; the reference does not show them at all.
4. **L2 — the Log has no Author/Date columns**, so identities and timestamps
   are only visible after selecting a commit.
5. **C9/L5 — the project tree lacks file-type icons and status chips.**
6. **L6 — Arbor carries more permanent toolbar chrome** than the reference.

## Method notes

- The captures are window screenshots of the running applications, taken by the
  XCUITest capture suite (`ui-smoke/ArborUIVisualCaptureUITests.swift`), not
  rendered mock-ups.
- The Rebased window is resized with a corner drag after unzooming; its Commit
  tool window is hidden through its own Hide control and restored through the
  activity rail afterwards.
- The fixture is identical for both applications, so row counts, branch names
  and timestamps match.
- Text is not compared glyph by glyph: the goal is layout and element
  inventory, which is what makes one screenshot recognisably “the same app” as
  the other.
