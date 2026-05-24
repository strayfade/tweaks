> [!WARNING]
> **This repo is not for you!** These tweaks are all WIP and this repository is hosting the tweak repo so that I am able to test tweaks on regular devices.

## Repository icon

[`repo.png`](repo.png) at the repo root is published as `CydiaIcon.png` on the apt site (the name Zebra, Sileo, and Cydia look for). Replace `repo.png` and push to `main` to update the icon.

## Package icons (Zebra / Sileo)

Per-tweak icons in package lists come from each tweak’s preference bundle icon at `prefs/Resources/icon.png`. On publish, those files are copied to `icons/<package-id>.png` and an `Icon:` URL is added to the `Packages` file. Add or replace `prefs/Resources/icon.png` in a tweak folder to set its store icon.

## Add the repository

In Sileo or Zebra, add this source:

```text
https://strayfade.github.io/tweaks/
```

## Packages

| Package | Description |
|---------|-------------|
| `com.strayfade.netsocket` | Compatibility with netsocket service |
| `com.noah.sensorusagelog` | Detailed sensor usage monitor with rankings |
| `com.noah.lstext` | Custom lock screen text in widget style |
| `com.noah.mcsplash` | Minecraft-style rotating splash text near the lock screen clock |
