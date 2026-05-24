#!/usr/bin/env bash
# Generate Packages / Packages.bz2 / Release for repo-output/ (apt repo root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${1:-$ROOT/repo-output}"
STATIC="${ROOT}/repo/static"
RELEASE_CONF="${ROOT}/repo/release.conf"

if [[ ! -d "$REPO_DIR/debs" ]]; then
  echo "No debs directory: $REPO_DIR/debs"
  exit 1
fi

shopt -s nullglob
debs=("$REPO_DIR/debs"/*.deb)
shopt -u nullglob

if [[ ${#debs[@]} -eq 0 ]]; then
  echo "No .deb files in $REPO_DIR/debs"
  exit 1
fi

mkdir -p "$REPO_DIR"
if [[ -d "$STATIC" ]]; then
  cp -a "$STATIC/." "$REPO_DIR/"
fi

cd "$REPO_DIR"
dpkg-scanpackages -m debs /dev/null > Packages
bzip2 -kf Packages

if [[ ! -f "$RELEASE_CONF" ]]; then
  echo "Missing $RELEASE_CONF"
  exit 1
fi

apt-ftparchive -c "$RELEASE_CONF" release . > Release

echo "Repository metadata written to $REPO_DIR"
ls -1 "$REPO_DIR"
