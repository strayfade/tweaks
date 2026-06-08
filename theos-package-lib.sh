#!/usr/bin/env bash
# Shared helpers for theos-package-local.sh and theos-package-remote.sh

theos_normalize_script() {
    local f="$1"
    if [[ -f "$f" ]]; then
        sed -i 's/\r$//' "$f" 2>/dev/null || true
    fi
}

theos_bump_control_version() {
    local tweak_dir="$1"
    local control_file="$tweak_dir/control"

    if [[ ! -f "$control_file" ]]; then
        return 0
    fi

    theos_normalize_script "$control_file"

    local current
    current="$(grep -E '^Version:[[:space:]]*' "$control_file" | head -1 | sed -E 's/^Version:[[:space:]]*//' | tr -d '\r')"
    if [[ -z "$current" ]]; then
        echo "No Version field in $control_file"
        return 1
    fi

    local new_version
    new_version="$(printf '%s\n' "$current" | awk -F. '{
        if (NF >= 3) { $3++; printf "%d.%d.%d", $1, $2, $3; next }
        if (NF == 2) { $2++; printf "%d.%d", $1, $2; next }
        $1++; print $1
    }')"

    if [[ -z "$new_version" || "$new_version" == "$current" ]]; then
        echo "Failed to bump version (current: $current)"
        return 1
    fi

    sed -i "s/^Version:.*/Version: $new_version/" "$control_file"
    echo "Version bumped: $current -> $new_version"
}

theos_copy_tweak_sources() {
    local tweak_dir="$1"
    local dest_dir="$2"

    mkdir -p "$dest_dir"
    shopt -s dotglob nullglob
    for item in "$tweak_dir"/*; do
        local base
        base="$(basename "$item")"
        if [[ "$base" != "build.sh" && "$base" != "build-and-upload.sh" ]]; then
            cp -a "$item" "$dest_dir/"
        fi
    done
    shopt -u dotglob nullglob
}

theos_make_rootless_package() {
    local dest_dir="$1"

    cd "$dest_dir"

    if [[ -f "control" ]]; then
        theos_normalize_script "control"
    fi

    make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

    shopt -s nullglob
    local deb_files=(packages/*.deb)
    shopt -u nullglob

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        echo "No .deb package found in $dest_dir/packages."
        return 1
    fi

    return 0
}

theos_load_device_env() {
    local tweak_dir="${1:?}"
    local repo_parent
    repo_parent="$(cd "$tweak_dir/.." && pwd)"
    local candidates=(
        "$tweak_dir/theos-device.env"
        "$repo_parent/theos-device.env"
        "${HOME}/.theos-device.env"
        "${HOME}/theos-device.env"
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

theos_normalize_device_env() {
    THEOS_DEVICE_IP="${THEOS_DEVICE_IP//$'\r'/}"
    THEOS_DEVICE_IP="${THEOS_DEVICE_IP//$'\n'/}"
    THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-mobile}"
    THEOS_DEVICE_USER="${THEOS_DEVICE_USER//$'\r'/}"
    THEOS_DEVICE_USER="${THEOS_DEVICE_USER//$'\n'/}"
    if [[ -n "${THEOS_DEVICE_SUDO_PASSWORD:-}" ]]; then
        THEOS_DEVICE_SUDO_PASSWORD="${THEOS_DEVICE_SUDO_PASSWORD//$'\r'/}"
        THEOS_DEVICE_SUDO_PASSWORD="${THEOS_DEVICE_SUDO_PASSWORD//$'\n'/}"
    fi
}

theos_file_mtime() {
    local f="$1"
    if stat -c %Y "$f" >/dev/null 2>&1; then
        stat -c %Y "$f"
    else
        stat -f %m "$f"
    fi
}

theos_pick_latest_deb() {
    local dir="${1:?}"
    local latest="" mtime=0 deb m
    shopt -s nullglob
    for deb in "$dir"/*.deb; do
        m="$(theos_file_mtime "$deb")"
        if (( m > mtime )); then
            mtime="$m"
            latest="$deb"
        fi
    done
    shopt -u nullglob
    if [[ -z "$latest" ]]; then
        echo "No .deb package found in $dir" >&2
        return 1
    fi
    printf '%s' "$latest"
}

theos_device_ssh_mux_init() {
    export _THEOS_SSH_TARGET="${THEOS_DEVICE_USER}@${THEOS_DEVICE_IP}"
    _THEOS_SSH_MUX_PATH=""
    THEOS_DEVICE_SSH_MUX_OPTS=()
    THEOS_DEVICE_SCP_MUX_OPTS=()
    if [[ "${THEOS_SSH_MUX:-1}" == "0" ]]; then
        return 0
    fi
    local mux_dir="${THEOS_SSH_MUX_DIR:-$HOME/.ssh}"
    mkdir -p "$mux_dir"
    local ip_safe="${THEOS_DEVICE_IP//:/_}"
    _THEOS_SSH_MUX_PATH="$mux_dir/theos-mux-${THEOS_DEVICE_USER}-at-${ip_safe}"
    THEOS_DEVICE_SSH_MUX_OPTS=(
        -o "ControlMaster=auto"
        -o "ControlPath=${_THEOS_SSH_MUX_PATH}"
        -o "ControlPersist=${THEOS_SSH_MUX_PERSIST:-300}"
    )
    THEOS_DEVICE_SCP_MUX_OPTS=("${THEOS_DEVICE_SSH_MUX_OPTS[@]}")
}

theos_device_ssh_mux_cleanup() {
    if [[ "${THEOS_SSH_MUX:-1}" == "0" ]] || [[ -z "${_THEOS_SSH_MUX_PATH:-}" ]]; then
        return 0
    fi
    if [[ -S "$_THEOS_SSH_MUX_PATH" ]] || [[ -e "$_THEOS_SSH_MUX_PATH" ]]; then
        ssh -o "BatchMode=yes" -o "ControlPath=${_THEOS_SSH_MUX_PATH}" -O exit "${_THEOS_SSH_TARGET}" 2>/dev/null || true
    fi
}

theos_install_deb_on_device() {
    local deb_file="${1:?}"
    local deb_name remote_deb escaped_password

    if [[ ! -f "$deb_file" ]]; then
        echo "Package not found: $deb_file" >&2
        return 1
    fi

    deb_name="$(basename "$deb_file")"
    remote_deb="/var/mobile/Media/PublicStaging/$deb_name"
    local ssh_target="${THEOS_DEVICE_USER}@${THEOS_DEVICE_IP}"

    echo "Uploading $deb_name to $ssh_target..."
    scp "${THEOS_DEVICE_SCP_MUX_OPTS[@]}" "$deb_file" "$ssh_target:$remote_deb"

    echo "Installing package on device..."
    local remote_install_body="dpkg -i '$remote_deb' && rm -f '$remote_deb' && (killall -9 SpringBoard)"

    if ssh "${THEOS_DEVICE_SSH_MUX_OPTS[@]}" "$ssh_target" "sudo -n true" 2>/dev/null; then
        ssh "${THEOS_DEVICE_SSH_MUX_OPTS[@]}" "$ssh_target" "sudo -n sh -c \"$remote_install_body\""
    else
        if [[ -z "${THEOS_DEVICE_SUDO_PASSWORD:-}" ]]; then
            echo "sudo on device requires a password. Set THEOS_DEVICE_SUDO_PASSWORD in theos-device.env." >&2
            return 1
        fi
        escaped_password="${THEOS_DEVICE_SUDO_PASSWORD//\'/\'\\\'\'}"
        ssh "${THEOS_DEVICE_SSH_MUX_OPTS[@]}" "$ssh_target" \
            "printf '%s\n' '$escaped_password' | sudo -S -p '' sh -c \"$remote_install_body\""
    fi

    echo "Install complete."
}
