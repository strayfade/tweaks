#!/usr/bin/env bash
# Shared: copy tweak -> temp dir, make package, upload .deb, install on device.
# Usage: theos-package-remote.sh /path/to/tweak/dir
#
# Configure once via env or a file (see theos-device.env.example). Searches:
#   <tweak>/theos-device.env  ->  <repo>/theos-device.env  ->  ~/.theos-device.env  ->  ~/theos-device.env

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

prompt_if_missing() {
    local var_name="$1"
    local prompt_text="$2"
    local is_secret="${3:-0}"
    local current_value="${!var_name:-}"

    if [[ -n "$current_value" ]]; then
        return
    fi

    if [[ "$is_secret" == "1" ]]; then
        read -rsp "$prompt_text: " current_value
        echo
    else
        read -rp "$prompt_text: " current_value
    fi

    if [[ -z "$current_value" ]]; then
        echo "Missing required value for $var_name."
        exit 1
    fi

    export "$var_name=$current_value"
}

theos_load_device_env "$TWEAK_DIR" || true

prompt_if_missing "THEOS_DEVICE_IP" "Device IP"

theos_normalize_device_env

if [[ -z "$THEOS_DEVICE_IP" || -z "$THEOS_DEVICE_USER" ]]; then
    echo "THEOS_DEVICE_IP and THEOS_DEVICE_USER must be non-empty after normalization."
    exit 1
fi

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

theos_device_ssh_mux_init
trap theos_device_ssh_mux_cleanup EXIT

theos_bump_control_version "$TWEAK_DIR"
theos_copy_tweak_sources "$TWEAK_DIR" "$DEST_DIR"
theos_make_rootless_package "$DEST_DIR"

latest_deb="$(theos_pick_latest_deb "$DEST_DIR/packages")"
theos_install_deb_on_device "$latest_deb"
