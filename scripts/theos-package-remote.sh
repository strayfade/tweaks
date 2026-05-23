#!/usr/bin/env bash
# Shared: copy tweak → temp dir, make package, upload .deb, install on device.
# Usage: theos-package-remote.sh /path/to/tweak/dir
#
# Configure once via env or a file (see theos-device.env.example). Searches:
#   <tweak>/theos-device.env  →  <repo>/theos-device.env  →  ~/.theos-device.env  →  ~/theos-device.env

set -euo pipefail

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

theos_load_device_env() {
    local d="$TWEAK_DIR"
    local repo_parent
    repo_parent="$(cd "$d/.." && pwd)"
    local candidates=(
        "$d/theos-device.env"
        "$repo_parent/theos-device.env"
        "$HOME/.theos-device.env"
        "$HOME/theos-device.env"
    )
    local f
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            echo "Device config: $f"
            set -a
            # shellcheck disable=SC1090
            source "$f"
            set +a
            return 0
        fi
    done
    return 1
}

theos_file_mtime() {
    local f="$1"
    if stat -c %Y "$f" >/dev/null 2>&1; then
        stat -c %Y "$f"
    else
        stat -f %m "$f"
    fi
}

theos_cleanup_ssh_mux() {
    if [[ "${THEOS_SSH_MUX:-1}" == "0" ]] || [[ -z "${_THEOS_SSH_MUX_PATH:-}" ]]; then
        return 0
    fi
    if [[ -S "$_THEOS_SSH_MUX_PATH" ]] || [[ -e "$_THEOS_SSH_MUX_PATH" ]]; then
        ssh -o "BatchMode=yes" -o "ControlPath=${_THEOS_SSH_MUX_PATH}" -O exit "${_THEOS_SSH_TARGET}" 2>/dev/null || true
    fi
}

theos_load_device_env || true

prompt_if_missing "THEOS_DEVICE_IP" "Device IP"
export THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-mobile}"

ssh_target="${THEOS_DEVICE_USER}@${THEOS_DEVICE_IP}"
export _THEOS_SSH_TARGET="$ssh_target"

# Reuse one SSH connection for scp + install (fewer auth prompts).
# Set THEOS_SSH_MUX=0 to disable.
_THEOS_SSH_MUX_PATH=""
ssh_mux_opts=()
scp_mux_opts=()
if [[ "${THEOS_SSH_MUX:-1}" != "0" ]]; then
    _THEOS_MUX_DIR="${THEOS_SSH_MUX_DIR:-$HOME/.ssh}"
    mkdir -p "$_THEOS_MUX_DIR"
    _THEOS_MUX_IP_SAFE="${THEOS_DEVICE_IP//:/_}"
    _THEOS_SSH_MUX_PATH="$_THEOS_MUX_DIR/theos-mux-${THEOS_DEVICE_USER}-at-${_THEOS_MUX_IP_SAFE}"
    ssh_mux_opts=(
        -o "ControlMaster=auto"
        -o "ControlPath=$_THEOS_SSH_MUX_PATH"
        -o "ControlPersist=${THEOS_SSH_MUX_PERSIST:-300}"
    )
    scp_mux_opts=("${ssh_mux_opts[@]}")
fi

trap theos_cleanup_ssh_mux EXIT

mkdir -p "$DEST_DIR"

shopt -s dotglob nullglob
for item in "$TWEAK_DIR"/*; do
    if [[ "$(basename "$item")" != "build.sh" ]]; then
        cp -a "$item" "$DEST_DIR/"
    fi
done
shopt -u dotglob nullglob

cd "$DEST_DIR"
make package THEOS_PACKAGE_SCHEME=rootless

shopt -s nullglob
deb_files=(packages/*.deb)
shopt -u nullglob

if [[ ${#deb_files[@]} -eq 0 ]]; then
    echo "No .deb package found in $DEST_DIR/packages."
    exit 1
fi

latest_deb=""
latest_mtime=0
for deb in "${deb_files[@]}"; do
    mtime="$(theos_file_mtime "$deb")"
    if (( mtime > latest_mtime )); then
        latest_mtime="$mtime"
        latest_deb="$deb"
    fi
done

remote_deb="/var/mobile/Media/PublicStaging/$(basename "$latest_deb")"

echo "Uploading $(basename "$latest_deb") to $ssh_target..."
scp "${scp_mux_opts[@]}" "$latest_deb" "$ssh_target:$remote_deb"

echo "Installing package on device..."
# One remote shell + one sudo where possible (password read once; works with NOPASSWD too).
remote_install_body="dpkg -i '$remote_deb' && rm -f '$remote_deb' && (killall -9 SpringBoard)"

if ssh "${ssh_mux_opts[@]}" "$ssh_target" "sudo -n true" 2>/dev/null; then
    ssh "${ssh_mux_opts[@]}" "$ssh_target" "sudo -n sh -c \"$remote_install_body\""
else
    if [[ -z "${THEOS_DEVICE_SUDO_PASSWORD:-}" ]]; then
        echo "sudo on device requires a password. Set THEOS_DEVICE_SUDO_PASSWORD in theos-device.env or enter when prompted."
        prompt_if_missing "THEOS_DEVICE_SUDO_PASSWORD" "Device sudo password" "1"
    fi
    escaped_password="${THEOS_DEVICE_SUDO_PASSWORD//\'/\'\\\'\'}"
    ssh "${ssh_mux_opts[@]}" "$ssh_target" "printf '%s\n' '$escaped_password' | sudo -S -p '' sh -c \"$remote_install_body\""
fi

echo "Install complete."
