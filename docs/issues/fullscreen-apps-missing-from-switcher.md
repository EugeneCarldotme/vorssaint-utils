# Fullscreen apps disappear from the app switcher

## Description

An app stops appearing in Vorssaint's app switcher when its window enters native macOS fullscreen. Zen and Helium Browser are the reported examples. The app remains running, but the switcher no longer offers it.

Expected behavior: fullscreen apps remain available across Spaces when fullscreen windows are enabled in the switcher, including with "Show only the current desktop" enabled. The user confirmed this policy during the investigation.

## Steps to reproduce

1. Enable "Show only the current desktop" and "Show fullscreen windows" in the switcher settings.
2. Open Zen or Helium Browser with a normal browser window.
3. Open Vorssaint's app switcher and confirm the browser appears.
4. Put the browser window into native macOS fullscreen.
5. Return to a regular desktop and open the app switcher again.
6. Check whether the browser still appears and can be selected. Also check the switcher while the fullscreen Space is active.

## Environment

- Feature area: Windows and Dock, app switcher.
- Installed Vorssaint version: 3.4.1.
- macOS: 27.0, build 26A428.
- Mac model: Mac17,9.
- The installed app has `switcherCurrentSpaceOnly` enabled.
- No explicit `switcherShowFullscreenWindows` preference is stored. Current main defaults this choice to enabled.
- Language, display layout and installation method have not been confirmed.

## Investigation

The browser symptom above is the user's report. A regression test reproduces the exclusion using the production enumeration methods and simulated WindowServer and Accessibility snapshots. Before the fix, three assertions fail because hidden fullscreen windows are filtered out.

Native fullscreen windows occupy separate Spaces. Both the WindowServer pass and the Accessibility-only pass apply the current-Space filter before the fullscreen-window preference. The fullscreen preference therefore cannot recover those entries.

The fix allows native fullscreen windows through this filter when fullscreen windows are shown. An Accessibility fullscreen flag or a native fullscreen Space confirms eligibility. A screen-sized ordinary window on another desktop remains excluded. Fullscreen entries retain their hidden-Space metadata. Dock Preview and Command Bar retain their existing scope policies.

The test covers both enumeration passes, a fullscreen window missing from Accessibility, app exclusions, cycle-excluded helpers, the fullscreen visibility toggle, desktop-travel metadata and other callers. Native Zen and Helium switcher visibility and activation remain unverified. Zen UI automation refused actions because it reported that the user had changed the app; no desktop or browser preference was changed for the test.

## Validation

- `./build.sh --test-suite=switcher-model`: passed, 1,804 checks.
- `./build.sh`: passed without compiler warnings.
- `./build/Vorssaint --selftest`: `SELFTEST OK`.
- `./build.sh --test`: `TESTS OK (115136 checks)`. Preference cleanup, uninstall-Spaces and Developer install-isolation checks passed.
- `git diff --check`: passed.
- `codesign --verify --deep --strict build/stage/Vorssaint.app`: passed.

## Acceptance criteria

- Keep fullscreen apps available across Spaces when "Show fullscreen windows" is enabled, even in current-desktop mode.
- Keep eligible fullscreen browser windows selectable under that policy.
- Preserve app exclusions, ordinary desktop filtering and the option to hide fullscreen windows.
- Cover the exclusion with a regression test that fails before the fix.
- State separately which native interactions were verified and which remain untested.

GitHub issue: [#2961](https://github.com/vorssaint/vorssaint-utils/issues/2961).
