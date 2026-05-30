#!/usr/bin/env bash
# Shared: copy tweak -> temp dir, make package (no upload/install).
# Usage: theos-package-local.sh /path/to/tweak/di

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/theos-package-lib.sh" ]]; then
    sed -i 's/\r$//' "$SCRIPT_DIR/theos-package-lib.sh" 2>/dev/null || true
fi
# shellcheck source=theos-package-lib.sh
source "$SCRIPT_DIR/theos-package-lib.sh"

TWEAK_DIR="${1:?Usage: $0 /path/to/tweak}"
TWEAK_DIR="$(cd "$TWEAK_DIR" && pwd)"

DEST_DIR="$HOME/theos_build_$(date +%s)"

# Ensure Theos paths are available in non-login shells (e.g., wsl -e / batch launchers).
if [[ -z "${THEOS:-}" ]]; then
    if [[ -d "$HOME/theos" ]]; then
        export THEOS="$HOME/theos"
    elif [[ -d "/opt/theos" ]]; then
        export THEOS="/opt/theos"
    fi
fi
if [[ -n "${THEOS:-}" ]] && [[ -z "${THEOS_MAKE_PATH:-}" ]]; then
    export THEOS_MAKE_PATH="$THEOS/makefiles"
fi
if [[ -z "${THEOS:-}" ]]; then
    echo "THEOS is not set and no default installation was found."
    echo "Set THEOS in your environment or install Theos to \$HOME/theos."
    exit 1
fi

theos_bump_control_version "$TWEAK_DIR"
theos_copy_tweak_sources "$TWEAK_DIR" "$DEST_DIR"
theos_make_rootless_package "$DEST_DIR"

echo "Package built in $DEST_DIR/packages"
