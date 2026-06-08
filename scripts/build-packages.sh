#!/usr/bin/env bash
# Build tweaks in scripts/tweaks.list; copy Mac-built debs from scripts/prebuilt-packages.list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="${ROOT}/scripts/tweaks.list"
PREBUILT_LIST="${ROOT}/scripts/prebuilt-packages.list"
OUTPUT="${ROOT}/repo-output/debs"
THEOS="${THEOS:-$HOME/theos}"
SCHEME="${THEOS_PACKAGE_SCHEME:-rootless}"

# shellcheck source=../theos-package-lib.sh
source "$ROOT/theos-package-lib.sh"

if [[ ! -d "$THEOS" ]]; then
  echo "THEOS is not set or does not exist: $THEOS"
  exit 1
fi

if [[ ! -f "$LIST" ]]; then
  echo "Missing tweak list: $LIST"
  exit 1
fi

mkdir -p "$OUTPUT"
rm -f "$OUTPUT"/*.deb

while IFS= read -r tweak || [[ -n "$tweak" ]]; do
  tweak="${tweak%%#*}"
  tweak="${tweak#"${tweak%%[![:space:]]*}"}"
  tweak="${tweak%"${tweak##*[![:space:]]}"}"
  [[ -n "$tweak" ]] || continue

  dir="$ROOT/$tweak"
  if [[ ! -d "$dir" ]]; then
    echo "Skipping missing tweak directory: $tweak"
    continue
  fi

  echo "==> Building $tweak"
  cd "$dir"
  if [[ -f control ]]; then
    sed -i 's/\r$//' control
  fi
  make clean package THEOS="$THEOS" THEOS_PACKAGE_SCHEME="$SCHEME" FINALPACKAGE=1

  shopt -s nullglob
  debs=(packages/*.deb)
  shopt -u nullglob

  if [[ ${#debs[@]} -eq 0 ]]; then
    echo "No .deb produced for $tweak"
    exit 1
  fi

  cp -a "${debs[@]}" "$OUTPUT/"
  cd "$ROOT"
done < "$LIST"

copy_prebuilt_packages() {
  local list_file="$1"
  [[ -f "$list_file" ]] || return 0

  while IFS= read -r tweak || [[ -n "$tweak" ]]; do
    tweak="${tweak%%#*}"
    tweak="${tweak#"${tweak%%[![:space:]]*}"}"
    tweak="${tweak%"${tweak##*[![:space:]]}"}"
    [[ -n "$tweak" ]] || continue

    local pkg_dir="$ROOT/$tweak/packages"
    if [[ ! -d "$pkg_dir" ]]; then
      echo "WARNING: Prebuilt packages directory missing for $tweak ($pkg_dir)"
      echo "         Build on a Mac, then commit the .deb under $tweak/packages/"
      continue
    fi

    local deb=""
    if [[ -f "$pkg_dir/release.deb" ]]; then
      deb="$pkg_dir/release.deb"
    elif ! deb="$(theos_pick_latest_deb "$pkg_dir")"; then
      echo "WARNING: No prebuilt .deb for $tweak in $pkg_dir"
      echo "         Build on a Mac, then run: bash scripts/stage-prebuilt-packages.sh"
      continue
    fi

    echo "==> Using prebuilt package for $tweak: $(basename "$deb")"
    cp -a "$deb" "$OUTPUT/"
  done < "$list_file"
}

copy_prebuilt_packages "$PREBUILT_LIST"

echo "Built packages:"
ls -1 "$OUTPUT"
