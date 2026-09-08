# App Switcher counts hidden cmux helper windows as separate windows

## Description

With one cmux window containing several workspaces, Vorssaint's App Switcher shows three windows for cmux. One preview shows the real terminal window; the other two are blank. The app icon also displays a window count of three.

The switcher should list actual switchable windows. Workspaces within a window and hidden helper windows should not add separate entries.

## Steps to reproduce

1. Open cmux with several workspaces inside one window.
2. Open Vorssaint's App Switcher with previews and app grouping enabled.
3. Select cmux and inspect its window previews and count.

Actual: three entries, including two blank previews.
Expected: one entry for the real cmux window.

The reported screenshot contains six workspaces but only three switcher entries. The extra entries are hidden helper windows, rather than one entry per workspace. Workspace count has not been established as the trigger.

## Diagnosis

Live inspection of cmux found one standard window titled `zsh` and two untitled `AXUnknown` windows measuring 800 × 600. Both helper windows carry macOS's exclude-from-window-cycling flag. One is transparent.

`WindowEnumerator.isUserFacingWindow` accepts normal-level `AXUnknown` windows without checking that flag. The Accessibility-only fallback can also restore the transparent helper after the WindowServer pass filters it out.

## Local fix

Honor the existing window-cycling exclusion flag when classifying nonstandard Accessibility windows. Filtering them before creating the Accessibility snapshot also keeps the fallback from restoring them. This uses macOS metadata and does not special-case cmux.

## Validation

- Live helper-window tags reproduce acceptance by the old predicate and rejection by the updated predicate.
- Regression checks cover both observed helper-window tag values.
- The original working tree passed 10,632 checks, preference-cleanup tests, a release build, and the bundled self-test. That tree also contained unrelated mixer edits.
- The changed app has not been installed or verified through the switcher UI.

## Environment

Feature area: Windows and Dock.
Affected app: cmux.
Exact installed app versions and macOS version were not recorded during diagnosis.
