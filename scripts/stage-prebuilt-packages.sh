#!/usr/bin/env bash
# Stage the latest committed .deb for each tweak in scripts/prebuilt-packages.list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREBUILT_LIST="${ROOT}/scripts/prebuilt-packages.list"

# shellcheck source=../theos-package-lib.sh
source "$ROOT/theos-package-lib.sh"

if [[ ! -f "$PREBUILT_LIST" ]]; then
  echo "Missing prebuilt package list: $PREBUILT_LIST"
  exit 1
fi

while IFS= read -r tweak || [[ -n "$tweak" ]]; do
  tweak="${tweak%%#*}"
  tweak="${tweak#"${tweak%%[![:space:]]*}"}"
  tweak="${tweak%"${tweak##*[![:space:]]}"}"
  [[ -n "$tweak" ]] || continue

  pkg_dir="$ROOT/$tweak/packages"
  deb="$(theos_pick_latest_deb "$pkg_dir")"
  release_deb="$pkg_dir/release.deb"
  cp -a "$deb" "$release_deb"
  echo "==> Staging $tweak: $(basename "$deb") -> packages/release.deb"
  git add -f "$release_deb"
done < "$PREBUILT_LIST"
