#!/usr/bin/env bash
# Build all tweaks and refresh apt repo metadata in repo-output/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT/scripts/build-packages.sh"
bash "$ROOT/scripts/update-repo.sh" "$ROOT/repo-output"
