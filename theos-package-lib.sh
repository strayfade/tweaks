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
