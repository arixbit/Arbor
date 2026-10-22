# UI smoke: click every control, require an observable change

The unit tests in `Arbor/ArborTests` prove that logic is correct. They cannot
prove that a button does anything. This suite covers that gap: it drives the
real app with XCUITest, clicks every visible control on a main surface, and
requires that each click produces something a user can observe — a changed
list, a dialog, a message, or a new state.

A click that changes nothing is reported as `DEAD` and fails the suite. That
is the definition of a silent no-op, which is the class of defect this suite
exists to catch.

## Running it

```sh
./scripts/ui-smoke.sh                       # build, then run every surface
./scripts/ui-smoke.sh --no-build            # reuse the last Debug build
./scripts/ui-smoke.sh --only ArborUISmokeUITests/testLogScreenControlsReact
./scripts/ui-smoke.sh --report build/ui-smoke-results

# Reproduce a single control the sweep reported as dead:
./scripts/ui-smoke.sh --focus "Go Up" --surface log
```

The suite builds the Debug app into `.build/DerivedData`, generates a
deterministic Git repository with `scripts/make-ui-fixture.sh`, and launches
that app bundle through `XCUIApplication(url:)`. It never depends on a
machine-specific DerivedData path, so the same command works locally and in
CI (`.github/workflows/ui-smoke.yml`).

## What is covered

| Surface | Test |
| --- | --- |
| Commit workbench | `testCommitScreenControlsReact` |
| Log workbench | `testLogScreenControlsReact` |
| Project tree | `testProjectTreeControlsReact` |
| Branches popover | `testBranchesPopoverControlsReact` |
| Settings | `testSettingsControlsReact` |
| Activity rail | `testActivityRailSwitchesViews` |
| Commit option checkboxes | `testCommitOptionCheckboxesToggle` |
| Project tree file rows | `testClickingAFileRowShowsItsContent` |
| Fetch without a remote | `testFetchWithoutRemoteExplainsWhy` (the message the user is left with) |

## How a click is judged

`ScreenState` is the normalized accessibility description of the app plus the
sheet, window and menu counts. The sweep records that state, clicks, and waits
for the state to differ. Anything that differs counts as observable — the
suite does not prescribe *which* reaction is correct, only that there is one.
Dedicated tests then pin the exact contract for controls where "something
changed" is not enough.

## Known limitations

- **Menus.** AppKit draws an open menu outside the application's accessibility
  subtree, so a menu click is indistinguishable from a dead click. Menu
  buttons are excluded from the sweep and covered by their own assertions
  instead of being reported as dead.
- **Stale subtrees.** SwiftUI keeps controls of a replaced pane in the
  accessibility tree, and they still report themselves as hittable. The sweep
  closes windows and dialogs a click opened, and `sweep(isolateOnSurfaceChange:)`
  can reload the app after every surface swap when a run needs it. Reproduce any
  remaining report with `--focus` before filing it.
- **Destructive controls.** Anything that leaves the fixture repository or the
  machine in a state the run cannot recover from (`Push…`, `Quit`, Finder
  reveals, dialogs that leave the app) is listed in `ArborUISweepPolicy` and
  excluded from the generic sweep.

## Recording the surfaces

`ArborUIDiagnosticsUITests` writes the accessibility tree of each surface into
the test log. When the sweep reports something unexpected, that dump is the
fastest way to see what the app actually exposed.
