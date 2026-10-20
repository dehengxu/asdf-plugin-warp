#!/usr/bin/env bash

# Install the Warp desktop app (Warp.app) into the active asdf install
# directory for the `warp` plugin.
#
# This is a separate, explicit step rather than something `asdf install` does
# behind your back:
#
#   * Warp.app ships as a .dmg, and mounting a disk image needs a normal
#     shell -- it is a privileged operation and fails inside sandboxes.
#   * /Applications is shared state, and silently replacing an app bundle
#     there would be rude.
#
# Usage:
#   install-macos-app.sh                 # use the version asdf has selected
#   install-macos-app.sh <version>       # use an explicit version
#   install-macos-app.sh --link          # also link into /Applications
#   install-macos-app.sh --unlink        # remove the /Applications link
#
# Set WARP_APP_LINK_PATH to point the symlink somewhere other than
# /Applications (used by the test suite).

set -euo pipefail

APP_NAME="Warp.app"
DEST="${WARP_APP_LINK_PATH:-/Applications/${APP_NAME}}"
ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
RELEASES="https://releases.warp.dev"

log() { printf '%s\n' "$*"; }
die() { printf 'install-macos-app: %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  die "this helper is macOS-only (you are on $(uname -s)); the Warp Agent CLI is what this plugin installs elsewhere"
fi

# --- helpers ----------------------------------------------------------------

_utils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_PY="${_utils_dir}/warp_releases.py"
PYTHON="${ASDF_WARP_PYTHON:-python3}"

host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    arm64 | aarch64) echo "aarch64" ;;
    x86_64 | amd64) echo "x86_64" ;;
    *) die "unsupported architecture '$m'" ;;
  esac
}

# The app ships an arm64-only bundle and a universal one; the universal build
# is what non-arm64 Macs get.
dmg_name() {
  if [ "$(host_arch)" = "aarch64" ]; then
    echo "Warp-arm64.dmg"
  else
    echo "Warp.dmg"
  fi
}

version_channel() {
  "${PYTHON}" "${RELEASES_PY}" channel "$1"
}

# Resolve the install directory for a version.
install_dir_for() {
  local version="$1" base="${ASDF_DATA_DIR}/installs/warp"
  [ -d "${base}/${version}" ] || die "no warp installation found at ${base}/${version}"
  printf '%s\n' "${base}/${version}"
}

# The version asdf currently has selected, falling back to the newest one
# installed.
selected_version() {
  if command -v asdf >/dev/null 2>&1; then
    local current
    current="$(asdf current warp 2>/dev/null || true)"
    if [ -n "$current" ]; then
      printf '%s\n' "$current" | awk '{print $NF}'
      return 0
    fi
  fi
  local base="${ASDF_DATA_DIR}/installs/warp"
  [ -d "$base" ] || return 1
  ls -1 "$base" 2>/dev/null | sort -V | tail -1
}

# --- argument parsing ------------------------------------------------------

mode="install"
version=""
link=0

for arg in "$@"; do
  case "$arg" in
    --link) link=1 ;;
    --unlink) mode="unlink" ;;
    -*) die "unknown argument: $arg" ;;
    *) version="$arg" ;;
  esac
done

if [ "$mode" = "unlink" ]; then
  if [ -L "$DEST" ]; then
    rm "$DEST"
    log "removed symlink ${DEST}"
  elif [ -e "$DEST" ]; then
    die "${DEST} is a real app, not a symlink — refusing to delete it"
  else
    log "nothing to do: ${DEST} does not exist"
  fi
  exit 0
fi

if [ -z "$version" ]; then
  version="$(selected_version)" || die "no warp installation found under ${ASDF_DATA_DIR}/installs/warp"
fi

# asdf versions have no `v` prefix; the download path needs it.
upstream_version="$version"
case "$upstream_version" in
  v*) : ;;
  *) upstream_version="v${upstream_version}" ;;
esac

channel="$(version_channel "$upstream_version")" ||
  die "'${version}' is not a Warp version string"
install_dir="$(install_dir_for "$version")"

url="${RELEASES}/${channel}/${upstream_version}/$(dmg_name)"
work_dir="${install_dir}/.dmg"
mount_point="${install_dir}/.mnt"

log "* Downloading ${url}"
mkdir -p "$work_dir"
dmg="${work_dir}/$(dmg_name)"
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$dmg" "$url" ||
  die "could not download ${url}"

log "* Mounting $(basename "$dmg")"
rm -rf "$mount_point"
mkdir -p "$mount_point"
hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg" >/dev/null ||
  die "could not mount ${dmg} (mounting a disk image needs a normal shell)"

cleanup() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rm -rf "$mount_point" "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT

[ -d "${mount_point}/${APP_NAME}" ] ||
  die "the mounted image does not contain ${APP_NAME}"

log "* Installing ${APP_NAME} into ${install_dir}"
rm -rf "${install_dir:?}/${APP_NAME}"
cp -R "${mount_point}/${APP_NAME}" "${install_dir}/${APP_NAME}" ||
  die "could not copy ${APP_NAME} into ${install_dir}"

# Warp.app is notarized, but a copy made here still carries the quarantine
# flag from the download.
xattr -dr com.apple.quarantine "${install_dir}/${APP_NAME}" 2>/dev/null || true

log "* ${APP_NAME} installed (warp ${version}, channel ${channel})"
log "  ${install_dir}/${APP_NAME}"

if [ "$link" = "1" ]; then
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    if [ ! -L "$DEST" ]; then
      log "${DEST} exists and is a real application bundle, not a symlink."
      log "It was probably installed via 'brew install --cask warp'. Pick one:"
      log "  1) keep the cask install:  brew uninstall --cask warp"
      log "  2) keep it and move it:    sudo mv '${DEST}' '${DEST}.bak'"
      log "Then re-run this script with --link."
      exit 1
    fi
    rm "$DEST"
  fi
  ln -s "${install_dir}/${APP_NAME}" "$DEST" ||
    die "could not create ${DEST} (you may need sudo)"
  log "  linked ${DEST} -> ${install_dir}/${APP_NAME}"
fi
