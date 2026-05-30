#!/usr/bin/env bash
# Build every tweak listed in scripts/tweaks.list and copy .deb files into repo-output/debs/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="${ROOT}/scripts/tweaks.list"
OUTPUT="${ROOT}/repo-output/debs"
THEOS="${THEOS:-$HOME/theos}"
SCHEME="${THEOS_PACKAGE_SCHEME:-rootless}"

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

echo "Built packages:"
ls -1 "$OUTPUT"
