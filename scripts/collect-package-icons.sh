#!/usr/bin/env bash
# Copy prefs bundle icons into repo-output/icons/<package-id>.png for Zebra/Sileo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_LIST="${ROOT}/scripts/tweaks.list"
PREBUILT_LIST="${ROOT}/scripts/prebuilt-packages.list"
REPO_DIR="${1:-$ROOT/repo-output}"
ICONS_DIR="$REPO_DIR/icons"

mkdir -p "$ICONS_DIR"
rm -f "$ICONS_DIR"/*.png

collect_icon_for_tweak() {
  local tweak="$1"
  local control="$ROOT/$tweak/control"
  local icon_src="$ROOT/$tweak/prefs/Resources/icon.png"

  if [[ ! -f "$control" ]]; then
    return 0
  fi

  local package
  package="$(awk -F': ' '/^Package:/ { print $2; exit }' "$control")"
  [[ -n "$package" ]] || return 0

  if [[ ! -f "$icon_src" ]]; then
    echo "No prefs icon for $package ($icon_src)"
    return 0
  fi

  cp -a "$icon_src" "$ICONS_DIR/${package}.png"
  echo "Package icon: $package"
}

collect_icons_from_list() {
  local list_file="$1"
  [[ -f "$list_file" ]] || return 0

  while IFS= read -r tweak || [[ -n "$tweak" ]]; do
    tweak="${tweak%%#*}"
    tweak="${tweak#"${tweak%%[![:space:]]*}"}"
    tweak="${tweak%"${tweak##*[![:space:]]}"}"
    [[ -n "$tweak" ]] || continue
    collect_icon_for_tweak "$tweak"
  done < "$list_file"
}

collect_icons_from_list "$BUILT_LIST"
collect_icons_from_list "$PREBUILT_LIST"

if ! compgen -G "$ICONS_DIR/*.png" > /dev/null; then
  echo "No package icons collected."
fi
