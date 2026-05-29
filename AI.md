# AI Agent Guide (Repo Style)

Use this as the default pattern when adding or refactoring tweaks in this repo.

## Basics
- All tweaks should be compatible with iOS 16.1.1 (Rootless) and similar versions.

## Preference Bundle Style (Shared)

- Use the same modern prefs layout used by `LSText`, `SplashText`, `SensorUsageLog`, and `netsocket`:
  1. Large header switch cell (`<Tweak>NameHeaderCell`)
  2. `Developer` group + custom developer card cell (`<Tweak>NameDeveloperCell`)
  3. Existing tweak settings grouped below developer
- Set plist title to a blank string: `<string> </string>`.

## Required Prefs Files

For a styled tweak prefs bundle, keep this structure:

- `prefs/<tweak>.mm` (controller with top-right menu + tint behavior)
- `prefs/TintColors.h`
- `prefs/Cells/<Tweak>HeaderCell.h/.mm`
- `prefs/Cells/<Tweak>DeveloperCell.h/.mm`
- `prefs/Resources/<tweak>.plist`
- `prefs/Resources/info.plist`
- `prefs/entry.plist`

## More about Preferences
- developer.png will need to be copied from existing tweaks into new ones.

## Build System Compatibility

In `prefs/Makefile`:

- Compile custom cells:
  - `<bundle>_FILES = <tweak>.mm $(wildcard Cells/*.m Cells/*.mm)`
- Keep ARC and package version define:
  - `<bundle>_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'`
- Stage PreferenceLoader entry plist in `internal-stage`.

## Respring Pattern

- In prefs controller, use `rootless.h` + `ROOT_PATH("/usr/bin/killall")`.
- Fallback shell command should be:
  - `killall -9 SpringBoard || sbreload || killall backboardd`
- Trigger via top-right gear menu action (`promptRespring`).

## Icons (Settings + Package Managers)

- Preference entry icon:
  - `prefs/entry.plist` must include `icon = icon.png;`
- Package manager icon export expects this exact file:
  - `prefs/Resources/icon.png`
- Package icon publish flow is automatic if tweak is listed in:
  - `scripts/tweaks.list`
- Repo scripts use that icon to populate `icons/<package-id>.png` and `Icon:` in `Packages`.

## Runtime Enable Switch

- If a large `Enabled` switch exists, ensure tweak runtime reads `Enabled` from:
  - `com.strayfade.<tweak>~prefs`
- Disabled state should short-circuit tweak behavior cleanly.

## Practical Safety Rules

- Preserve existing user settings/keys unless explicitly asked to rename/remove.
- Prefer matching established naming and spacing from existing styled tweaks.
- After edits, run lint checks on touched files.
- Avoid destructive git operations.
