#!/usr/bin/env bash
# Build on Mac via SSH, download .deb, install on test device (same flow as other tweaks' build-and-upload.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$ROOT/build-mac-remote.sh" "$@"
