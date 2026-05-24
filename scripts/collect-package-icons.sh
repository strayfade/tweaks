#!/usr/bin/env bash
# Copy prefs bundle icons into repo-output/icons/<package-id>.png for Zebra/Sileo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="${ROOT}/scripts/tweaks.list"
REPO_DIR="${1:-$ROOT/repo-output}"
ICONS_DIR="$REPO_DIR/icons"

mkdir -p "$ICONS_DIR"
rm -f "$ICONS_DIR"/*.png

while IFS= read -r tweak || [[ -n "$tweak" ]]; do
  tweak="${tweak%%#*}"
  tweak="${tweak#"${tweak%%[![:space:]]*}"}"
  tweak="${tweak%"${tweak##*[![:space:]]}"}"
  [[ -n "$tweak" ]] || continue

  control="$ROOT/$tweak/control"
  icon_src="$ROOT/$tweak/prefs/Resources/icon.png"

  if [[ ! -f "$control" ]]; then
    continue
  fi

  package="$(awk -F': ' '/^Package:/ { print $2; exit }' "$control")"
  [[ -n "$package" ]] || continue

  if [[ ! -f "$icon_src" ]]; then
    echo "No prefs icon for $package ($icon_src)"
    continue
  fi

  cp -a "$icon_src" "$ICONS_DIR/${package}.png"
  echo "Package icon: $package"
done < "$LIST"

if ! compgen -G "$ICONS_DIR/*.png" > /dev/null; then
  echo "No package icons collected."
fi
