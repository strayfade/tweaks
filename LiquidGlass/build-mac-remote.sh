#!/usr/bin/env bash
# Sync LiquidGlass sources to a Mac over SSH, run Theos "make package" there,
# copy packages/*.deb back, then install on a test device (like build-and-upload.sh).
#
# Requires (Ubuntu / WSL): openssh-client, rsync, sshpass, tar
#   sudo apt-get install -y openssh-client rsync sshpass tar
#
# Mac SSH: build-mac-remote.env (see build-mac-remote.env.example)
# Device:  theos-device.env (see ../theos-device.env.example)
#
# Windows: build-mac-remote-and-upload.bat or build-mac-remote.bat

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/build-mac-remote.env"
TAG="[LiquidGlass/mac-remote]"

MAC_BUILD_HOST="${MAC_BUILD_HOST:-}"
MAC_BUILD_USER="${MAC_BUILD_USER:-}"
MAC_BUILD_PASSWORD="${MAC_BUILD_PASSWORD:-}"
MAC_BUILD_REMOTE_DIR="${MAC_BUILD_REMOTE_DIR:-theos_remote/LiquidGlass}"
MAC_BUILD_THEOS="${MAC_BUILD_THEOS:-}"
MAC_BUILD_SCHEME="${MAC_BUILD_SCHEME:-rootless}"
MAC_BUILD_SKIP_CLEAN="${MAC_BUILD_SKIP_CLEAN:-1}"

THEOS_DEVICE_IP="${THEOS_DEVICE_IP:-}"
THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-}"
THEOS_DEVICE_SUDO_PASSWORD="${THEOS_DEVICE_SUDO_PASSWORD:-}"

CONFIGURE_ONLY=0
CONFIGURE_DEVICE_ONLY=0
SKIP_SAVE=0
SKIP_DEVICE_INSTALL=0

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../theos-package-lib.sh
source "$REPO_ROOT/theos-package-lib.sh"

usage() {
    cat <<'EOF'
Usage: ./build-mac-remote.sh [options]

  --configure         Prompt for Mac SSH settings and save build-mac-remote.env, then exit.
  --configure-device  Prompt for test device settings and save theos-device.env, then exit.
  --reconfigure       Force Mac SSH prompts even if build-mac-remote.env exists.
  --no-save           Do not write env files after prompting.
  --no-install        Build and download .deb only; do not install on device.
  -h, --help          Show this help.

Packages land in ./packages/. Device install uses theos-device.env (repo or tweak folder).
EOF
}

save_device_env() {
    local device_env="$SCRIPT_DIR/theos-device.env"
    if [[ "$SKIP_SAVE" == "1" ]]; then
        return 0
    fi
    umask 077
    {
        echo "# Saved by build-mac-remote.sh — do not commit."
        printf 'export THEOS_DEVICE_IP=%q\n' "$(normalize_value "$THEOS_DEVICE_IP")"
        printf 'export THEOS_DEVICE_USER=%q\n' "$(normalize_value "${THEOS_DEVICE_USER:-mobile}")"
        printf 'export THEOS_DEVICE_SUDO_PASSWORD=%q\n' "$(normalize_value "$THEOS_DEVICE_SUDO_PASSWORD")"
    } >"$device_env"
    chmod 600 "$device_env"
    echo "$TAG Saved device settings to $device_env"
}

configure_device_settings() {
    prompt_if_empty THEOS_DEVICE_IP "Test device IP address"
    THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-mobile}"
    prompt_if_empty THEOS_DEVICE_USER "Test device SSH user" 0
    prompt_if_empty THEOS_DEVICE_SUDO_PASSWORD "Device sudo password (Alpine)" 1
    save_device_env
}

normalize_value() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v//$'\n'/}"
    printf '%s' "$v"
}

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        return 0
    fi
    echo "$TAG Using config: $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

save_env() {
    if [[ "$SKIP_SAVE" == "1" ]]; then
        return 0
    fi
    umask 077
    {
        echo "# Saved by build-mac-remote.sh — do not commit."
        printf 'export MAC_BUILD_HOST=%q\n' "$(normalize_value "$MAC_BUILD_HOST")"
        printf 'export MAC_BUILD_USER=%q\n' "$(normalize_value "$MAC_BUILD_USER")"
        printf 'export MAC_BUILD_PASSWORD=%q\n' "$(normalize_value "$MAC_BUILD_PASSWORD")"
        printf 'export MAC_BUILD_REMOTE_DIR=%q\n' "$(normalize_value "$MAC_BUILD_REMOTE_DIR")"
        printf 'export MAC_BUILD_SCHEME=%q\n' "$(normalize_value "$MAC_BUILD_SCHEME")"
        printf 'export MAC_BUILD_SKIP_CLEAN=%q\n' "$(normalize_value "$MAC_BUILD_SKIP_CLEAN")"
        if [[ -n "$MAC_BUILD_THEOS" ]]; then
            printf 'export MAC_BUILD_THEOS=%q\n' "$(normalize_value "$MAC_BUILD_THEOS")"
        fi
    } >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "$TAG Saved settings to $ENV_FILE"
}

prompt_if_empty() {
    local var_name="$1"
    local prompt_text="$2"
    local is_secret="${3:-0}"
    local current
    current="$(normalize_value "${!var_name:-}")"

    if [[ -n "$current" ]]; then
        printf -v "$var_name" '%s' "$current"
        return 0
    fi

    if [[ "$is_secret" == "1" ]]; then
        read -rsp "$prompt_text: " current
        echo
    else
        read -rp "$prompt_text: " current
    fi
    current="$(normalize_value "$current")"
    if [[ -z "$current" ]]; then
        echo "$TAG Missing required value for $var_name."
        exit 1
    fi
    printf -v "$var_name" '%s' "$current"
}

require_tools() {
    local missing=()
    for tool in ssh rsync sshpass tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "$TAG Missing tools: ${missing[*]}"
        echo "$TAG Install on Ubuntu/WSL:"
        echo "  sudo apt-get update && sudo apt-get install -y openssh-client rsync sshpass tar"
        exit 1
    fi
}

remote_build_dir() {
    if [[ "$REMOTE_REL" == /* ]]; then
        printf '%s' "$REMOTE_REL"
    else
        printf '~/%s' "$REMOTE_REL"
    fi
}

verify_local_sources() {
    echo "$TAG Checking local sources ..."
    local missing=()
    for f in Makefile Tweak.x control prefs/Makefile prefs/liquidglass.mm prefs/entry.plist; do
        if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "$TAG Missing local files (not on disk — save or restore prefs sources):"
        printf '  %s\n' "${missing[@]}"
        exit 1
    fi
}

upload_sources() {
    local remote_dir tar_excludes=() remote_shell
    remote_dir="$(remote_build_dir)"
    echo "$TAG Uploading sources to Mac:${remote_dir} (tar) ..."

    tar_excludes=(
        --exclude='./.git'
        --exclude='./packages'
        --exclude='./.theos'
        --exclude='./obj'
        --exclude='./build-mac-remote.env'
        --exclude='./LiquidGlassKit-main'
        --exclude='./.DS_Store'
    )

    # WSL/Windows mounts often produce 777 modes; dpkg-deb rejects control dirs outside 0755–0775.
    local chmod_tree='find . -type d -exec chmod 755 {} +; find . -type f -exec chmod 644 {} +'
    if [[ "$REMOTE_REL" == /* ]]; then
        remote_shell="mkdir -p $(printf '%q' "$REMOTE_REL") && cd $(printf '%q' "$REMOTE_REL") && tar xzf - && ${chmod_tree}"
    else
        remote_shell="mkdir -p ~/$(printf '%q' "$REMOTE_REL") && cd ~/$(printf '%q' "$REMOTE_REL") && tar xzf - && ${chmod_tree}"
    fi

    SSHPASS="$(normalize_value "$MAC_BUILD_PASSWORD")"
    export SSHPASS
    (cd "$SCRIPT_DIR" && tar czf - "${tar_excludes[@]}" .) | \
        sshpass -e ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$remote_shell"
}

verify_remote_sources() {
    echo "$TAG Verifying sources on Mac ..."
    SSHPASS="$(normalize_value "$MAC_BUILD_PASSWORD")"
    export SSHPASS
    sshpass -e ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
        env "REMOTE_REL=$REMOTE_REL" bash -s <<'VERIFY'
set -euo pipefail
if [[ "$REMOTE_REL" == /* ]]; then
  cd "$REMOTE_REL"
else
  cd "$HOME/$REMOTE_REL"
fi
missing=()
for f in Makefile Tweak.x prefs/Makefile control; do
  if [[ ! -f "$f" ]]; then
    missing+=("$f")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing on Mac after upload: ${missing[*]}"
  echo "--- prefs listing ---"
  ls -la prefs 2>/dev/null || echo "(no prefs directory)"
  exit 1
fi
VERIFY
}

run_remote_build() {
    SCHEME="$(normalize_value "$MAC_BUILD_SCHEME")"
    echo "$TAG Building on Mac (scheme=${SCHEME}, skip_clean=${MAC_BUILD_SKIP_CLEAN}) ..."
    SSHPASS="$(normalize_value "$MAC_BUILD_PASSWORD")"
    export SSHPASS
    sshpass -e ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
        env \
        "REMOTE_REL=$REMOTE_REL" \
        "MAC_BUILD_SCHEME=$SCHEME" \
        "MAC_BUILD_SKIP_CLEAN=$(normalize_value "$MAC_BUILD_SKIP_CLEAN")" \
        "MAC_BUILD_THEOS=$(normalize_value "$MAC_BUILD_THEOS")" \
        bash -s <<'REMOTE_BUILD'
set -euo pipefail
if [[ "$REMOTE_REL" == /* ]]; then
  cd "$REMOTE_REL"
else
  cd "$HOME/$REMOTE_REL"
fi
find . -type d -exec chmod 755 {} +
find . -type f -exec chmod 644 {} +
if [[ -n "${MAC_BUILD_THEOS:-}" ]]; then
  export THEOS="$MAC_BUILD_THEOS"
elif [[ -d "$HOME/theos" ]]; then
  export THEOS="$HOME/theos"
else
  echo "THEOS is not set and $HOME/theos was not found on the Mac."
  exit 1
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ -x /opt/homebrew/opt/make/libexec/gnubin/make ]]; then
  MAKE=/opt/homebrew/opt/make/libexec/gnubin/make
else
  MAKE=make
fi
if [[ "$MAC_BUILD_SKIP_CLEAN" != "1" ]]; then
  "$MAKE" clean
fi
"$MAKE" package THEOS_PACKAGE_SCHEME="$MAC_BUILD_SCHEME" FINALPACKAGE=1
echo "--- Mac packages ---"
ls -1 packages/*.deb
REMOTE_BUILD
}

install_on_device() {
    local deb_file="$1"
    echo "$TAG Installing on test device ..."
    theos_load_device_env "$SCRIPT_DIR" || true
    theos_normalize_device_env
    export THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-mobile}"

    if [[ -z "$(normalize_value "${THEOS_DEVICE_IP:-}")" ]]; then
        echo "$TAG No device IP — run with --configure-device or create theos-device.env"
        prompt_if_empty THEOS_DEVICE_IP "Test device IP address"
        THEOS_DEVICE_USER="${THEOS_DEVICE_USER:-mobile}"
        prompt_if_empty THEOS_DEVICE_USER "Test device SSH user" 0
        prompt_if_empty THEOS_DEVICE_SUDO_PASSWORD "Device sudo password (Alpine)" 1
        save_device_env
    fi

    theos_normalize_device_env
    if [[ -z "$THEOS_DEVICE_IP" ]]; then
        echo "$TAG THEOS_DEVICE_IP is required for install."
        exit 1
    fi

    theos_device_ssh_mux_init
    trap theos_device_ssh_mux_cleanup EXIT
    theos_install_deb_on_device "$deb_file"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure)
            CONFIGURE_ONLY=1
            ;;
        --configure-device)
            CONFIGURE_DEVICE_ONLY=1
            ;;
        --reconfigure)
            MAC_BUILD_HOST=""
            MAC_BUILD_USER=""
            MAC_BUILD_PASSWORD=""
            ;;
        --no-save)
            SKIP_SAVE=1
            ;;
        --no-install)
            SKIP_DEVICE_INSTALL=1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "$TAG Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

load_env
require_tools

if [[ "$CONFIGURE_DEVICE_ONLY" == "1" ]]; then
    configure_device_settings
    echo "$TAG Device configuration saved."
    exit 0
fi

if [[ "$CONFIGURE_ONLY" == "1" ]] || [[ -z "$(normalize_value "$MAC_BUILD_HOST")" ]]; then
    prompt_if_empty MAC_BUILD_HOST "Mac IP address or hostname"
    prompt_if_empty MAC_BUILD_USER "Mac SSH username"
    prompt_if_empty MAC_BUILD_PASSWORD "Mac SSH password" 1
    read -rp "Remote build directory on Mac [$MAC_BUILD_REMOTE_DIR]: " _dir || true
    if [[ -n "${_dir:-}" ]]; then
        MAC_BUILD_REMOTE_DIR="$(normalize_value "$_dir")"
    fi
    save_env
    if [[ "$CONFIGURE_ONLY" == "1" ]]; then
        echo "$TAG Configuration saved."
        exit 0
    fi
else
    MAC_BUILD_HOST="$(normalize_value "$MAC_BUILD_HOST")"
    MAC_BUILD_USER="$(normalize_value "$MAC_BUILD_USER")"
    MAC_BUILD_PASSWORD="$(normalize_value "$MAC_BUILD_PASSWORD")"
    if [[ -z "$MAC_BUILD_HOST" || -z "$MAC_BUILD_USER" || -z "$MAC_BUILD_PASSWORD" ]]; then
        echo "$TAG Incomplete config in $ENV_FILE — run with --configure"
        exit 1
    fi
fi

SSH_TARGET="${MAC_BUILD_USER}@${MAC_BUILD_HOST}"
REMOTE_REL="${MAC_BUILD_REMOTE_DIR:-theos_remote/LiquidGlass}"
REMOTE_REL="${REMOTE_REL#/}"

if [[ "$REMOTE_REL" == /* ]]; then
    RSYNC_REMOTE_PREFIX="${SSH_TARGET}:${REMOTE_REL}"
else
    RSYNC_REMOTE_PREFIX="${SSH_TARGET}:~/${REMOTE_REL}"
fi

RSYNC_SSH="sshpass -e ssh -o StrictHostKeyChecking=accept-new"

theos_bump_control_version "$SCRIPT_DIR"

verify_local_sources
upload_sources
verify_remote_sources
run_remote_build

LOCAL_PACKAGES="$SCRIPT_DIR/packages"
mkdir -p "$LOCAL_PACKAGES"

echo "$TAG Downloading packages to $LOCAL_PACKAGES ..."
SSHPASS="$(normalize_value "$MAC_BUILD_PASSWORD")"
export SSHPASS
if ! rsync -avz -e "$RSYNC_SSH" \
    "${RSYNC_REMOTE_PREFIX}/packages/" \
    "$LOCAL_PACKAGES/"; then
    echo "$TAG Failed to download packages from Mac."
    exit 1
fi

shopt -s nullglob
debs=("$LOCAL_PACKAGES"/*.deb)
shopt -u nullglob

if [[ ${#debs[@]} -eq 0 ]]; then
    echo "$TAG Build finished but no .deb files were found in $LOCAL_PACKAGES"
    exit 1
fi

latest_deb="$(theos_pick_latest_deb "$LOCAL_PACKAGES")"
echo "$TAG Built package: $(basename "$latest_deb")"

if [[ "$SKIP_DEVICE_INSTALL" == "1" ]]; then
    echo "$TAG Skipping device install (--no-install)."
    exit 0
fi

install_on_device "$latest_deb"
echo "$TAG Done."
