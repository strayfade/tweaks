# strayfade tweaks

Collection of iOS jailbreak tweaks. Packages are built in CI and published as an APT repository for **Sileo**, **Zebra**, and other frontends.

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

## Enable GitHub Pages (one-time)

After the first workflow run on `main`:

1. Open **Settings → Pages** on [github.com/strayfade/tweaks](https://github.com/strayfade/tweaks).
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
3. Choose branch **`gh-pages`**, folder **`/ (root)`**, then save.

The apt repo URL above will work once Pages is enabled and the workflow has finished.

## Development

Each tweak lives in its own folder with a Theos `Makefile` and `control` file.

**Windows (WSL):** build and install on a connected device:

```bat
build-all.bat
build-all.bat MCSplash
```

**Linux / macOS / WSL:** build only the apt repo output locally:

```bash
export THEOS=~/theos
export THEOS_PACKAGE_SCHEME=rootless
bash scripts/build-repo.sh
```

To include a new tweak in the published repo, add its folder name to [`scripts/tweaks.list`](scripts/tweaks.list).

Pushing to `main` rebuilds all listed packages and updates the `gh-pages` branch automatically (see [`.github/workflows/apt-repo.yml`](.github/workflows/apt-repo.yml)).
