# App Switcher lists remembered workspaces as separate windows after they are closed

## Description

Apps with remembered workspaces can retain them after they are closed. The reported bug is that Vorssaint continues to list these retained workspaces as separate windows even though they are no longer open windows. Reported examples are cmux and Ghostty.

In the supplied cmux screenshot, with one window containing several workspaces, Vorssaint's App Switcher shows three windows for cmux. One preview shows the real terminal window; the other two are blank. The app icon also displays a window count of three.

The switcher should list actual switchable windows. Remembered workspaces that have been closed, workspaces within an existing window, and hidden helper windows should not add separate entries. Actual open windows, including minimized windows and windows on other Spaces, should remain switchable.

## Steps to reproduce

1. Open an app that remembers workspaces, such as cmux or Ghostty, and create several workspaces.
2. Close workspaces while the app retains them for later restoration. Leave one actual window open.
3. Open Vorssaint's App Switcher with previews and app grouping enabled.
4. Select the app and inspect its window previews and count.

Actual: extra entries remain for workspaces that are no longer open windows. The supplied cmux screenshot shows three entries, including two blank previews.
Expected: one entry for each actual open window, without entries for closed, remembered workspaces.

The close-and-retain sequence above reflects the reported behavior. It has not yet been reproduced during investigation, and Ghostty has not been inspected. The cmux inspection below establishes a helper-window filtering problem but does not establish how those windows relate to remembered workspaces.

## Diagnosis

Live inspection of cmux found one standard window titled `zsh` and two untitled `AXUnknown` windows measuring 800 × 600. Both helper windows carry macOS's exclude-from-window-cycling flag. One is transparent.

`WindowEnumerator.isUserFacingWindow` accepts normal-level `AXUnknown` windows without checking that flag. The Accessibility-only fallback can also restore the transparent helper after the WindowServer pass filters it out.

## Local fix and remaining verification

Honor the existing window-cycling exclusion flag when classifying nonstandard Accessibility windows. Filtering them before creating the Accessibility snapshot also keeps the fallback from restoring them. This uses macOS metadata and does not special-case cmux.

This fix addresses the verified cmux helper-window case. Reproduce closing and retaining workspaces in both cmux and Ghostty to determine whether it also resolves the full reported issue or whether another enumeration path needs correction.

## Validation

- Live helper-window tags reproduce acceptance by the old predicate and rejection by the updated predicate.
- Regression checks cover both observed helper-window tag values.
- The original working tree passed 10,632 checks, preference-cleanup tests, a release build, and the bundled self-test. That tree also contained unrelated mixer edits.
- The changed app has not been installed or verified through the switcher UI.

## Environment

Feature area: Windows and Dock.
Reported affected apps: cmux and Ghostty.
Live inspection performed: cmux only.
Exact installed app versions and macOS version were not recorded during diagnosis.
