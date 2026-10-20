#!/usr/bin/env bash

# Shared helpers for the asdf `warp` plugin.
#
# Warp ships the Warp Agent CLI ("warp" command) as a prebuilt, versioned,
# per-architecture tarball on Google Cloud Storage, which is exactly the shape
# asdf's version model expects. There is no compilation step.
#
# The download layout mirrors what Warp's own install script does:
#
#   <version>/warp-tui-<channel>   the executable
#   <version>/resources/            settings schema, bundled skills, licenses
#
# The executable keeps its upstream name because the release channel is baked
# into it, and the `resources/` sibling is resolved relative to the real
# executable path -- so the shim is a wrapper script, never a symlink.
#
# Supported hosts: macOS (arm64/x64), Linux (arm64/x64).

set -euo pipefail

TOOL_NAME="warp"

_utils_self="${BASH_SOURCE[0]:-$0}"
_utils_dir="$(cd "$(dirname "$_utils_self")" && pwd)"
RELEASES_PY="${_utils_dir}/warp_releases.py"
PYTHON="${ASDF_WARP_PYTHON:-python3}"

fail() {
  echo -e "asdf-${TOOL_NAME}: $*" >&2
  exit 1
}

# --- platform detection -----------------------------------------------------

# Warp's own artifact tokens: "macos" and "linux".
host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *) fail "unsupported OS '$(uname -s)' (the Warp Agent CLI ships for macOS and Linux)" ;;
  esac
}

# True on Apple Silicon hardware, even from inside a translated process.
_is_apple_silicon() {
  [ "$(uname -s)" = "Darwin" ] || return 1
  # hw.optional.arm64 is a hardware feature flag, so it keeps reporting 1
  # even from a Rosetta-translated process.
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
    return 0
  fi
  # Fallback for hardened environments where sysctl is unavailable: ask the
  # kernel to actually execute an arm64 binary.
  arch -arm64 /usr/bin/true >/dev/null 2>&1
}

# Warp's artifact tokens: "aarch64" and "x86_64".
#
# `uname -m` reports the *process* architecture, which lies under Rosetta 2:
# an x86_64 shell on Apple Silicon spawns these scripts with a translated
# environment where `uname -m` answers x86_64, and we would then install the
# Intel build on a machine that has the native one. Query the hardware, not
# the process.
host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    arm64 | aarch64) echo "aarch64" ;;
    x86_64 | amd64)
      if _is_apple_silicon; then echo "aarch64"; else echo "x86_64"; fi
      ;;
    *) fail "unsupported architecture '$m'" ;;
  esac
}

# --- version listing --------------------------------------------------------

list_all_versions() {
  "${PYTHON}" "${RELEASES_PY}" list "$@"
}

latest_stable_version() {
  "${PYTHON}" "${RELEASES_PY}" latest stable
}

# Channel a version belongs to, e.g. "stable" for 0.2026.10.14.08.27.stable_01.
version_channel() {
  "${PYTHON}" "${RELEASES_PY}" channel "$1"
}

# --- download ---------------------------------------------------------------

artifact_url() {
  local version="$1"
  "${PYTHON}" "${RELEASES_PY}" url "$version" "$(host_os)" "$(host_arch)"
}

# The expected md5 (base64) as published by Google Cloud Storage.
artifact_md5() {
  local version="$1"
  "${PYTHON}" "${RELEASES_PY}" md5 "$version" "$(host_os)" "$(host_arch)"
}

# Local md5 of a file, base64 encoded -- the same encoding GCS publishes.
file_md5_b64() {
  local file="$1" digest
  digest="$(md5 -q "$file" 2>/dev/null || true)"
  if [ -z "$digest" ]; then
    # BSD `md5 -q` prints the bare hash; fall back to a portable form.
    digest="$(md5sum "$file" 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "$digest" ] || return 1
  printf '%s' "$digest" | xxd -r -p | base64
}

# 0 when the file matches the digest published by GCS, 2 when no digest
# could be fetched, 1 on mismatch.
verify_md5() {
  local file="$1" version="$2" want got
  [ -s "$file" ] || return 1

  want="$("${PYTHON}" "${RELEASES_PY}" md5 "$version" "$(host_os)" "$(host_arch)" 2>/dev/null)" || return 2

  got="$(file_md5_b64 "$file")" || return 2
  if [ "$got" != "$want" ]; then
    echo "* md5 MISMATCH for $(basename "$file")" >&2
    echo "*   expected ${want}" >&2
    echo "*   actual   ${got}" >&2
    return 1
  fi
  return 0
}

# Hard integrity gate for what we actually received.
#
# Google Cloud Storage publishes the digest of the *stored* object, which it
# keeps gzip-encoded (`x-goog-stored-content-encoding: gzip`). A client that
# does not ask for gzip is served the transparently decompressed bytes
# instead, so the published digest covers a different byte sequence than the
# one on disk -- the two legitimately disagree even for a pristine download.
#
# The gzip trailer carries a CRC32 over the whole uncompressed tar, so
# `gzip -t` is the authoritative check for the bytes we hold.
verify_archive() {
  local file="$1"
  [ -s "$file" ] || return 1
  gzip -t "$file" >/dev/null 2>&1
}

download_release() {
  local version="$1" url filename
  url="$(artifact_url "$version")" ||
    fail "no build for $(host_os)/$(host_arch) at ${version}"
  filename="${ASDF_DOWNLOAD_PATH:-${TMPDIR:-/tmp}}/$(basename "$url")"

  mkdir -p "$(dirname "$filename")"

  if [ -s "$filename" ]; then
    if verify_md5 "$filename" "$version"; then
      echo "* Reusing verified download: $(basename "$filename")"
      return 0
    fi
    if verify_archive "$filename"; then
      echo "* Reusing existing download: $(basename "$filename") (archive CRC ok)"
      return 0
    fi
    echo "* Existing file failed its CRC check, re-downloading..."
  fi

  echo "* Downloading warp ${version} [$(basename "$url")]..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$filename" "$url" ||
    fail "could not download ${url}"

  if verify_md5 "$filename" "$version"; then
    echo "* md5 verified against the digest published by Google Cloud Storage"
  else
    local rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "* WARNING: no published digest available; skipping verification" >&2
    else
      echo "* WARNING: md5 differs from the digest published by Google Cloud Storage." >&2
      echo "*          The published digest covers the stored (gzip-encoded) object," >&2
      echo "*          while we received the decompressed bytes. Falling back to" >&2
      echo "*          the archive's own CRC32 check." >&2
    fi
  fi

  verify_archive "$filename" ||
    fail "archive failed its CRC check (truncated or corrupt download): ${filename}"
  echo "* archive CRC32 verified"
}

# --- install ----------------------------------------------------------------

# Name of the executable inside the tarball, e.g. "warp-tui-stable".
binary_name() {
  local channel="$1"
  echo "warp-tui-${channel}"
}

_write_wrapper() {
  local bin_dir="$1" channel="$2" binary

  binary="$(binary_name "$channel")"

  # Deliberately a wrapper script and NOT a symlink: the payload resolves its
  # `resources/` directory relative to the real executable path. exec'ing
  # through a symlink makes process.execPath point at the shim and the
  # resources are not found. `exec` replaces this shell, so the child sees
  # the genuine executable path.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Generated by the asdf warp plugin.' \
    'here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    "exec \"\${here}/../${binary}\" \"\$@\"" \
    > "${bin_dir}/${TOOL_NAME}"
  chmod +x "${bin_dir}/${TOOL_NAME}"
}

install_version() {
  local version="$1" install_path="$2"
  local archive channel binary bin_dir

  channel="$(version_channel "$version")" ||
    fail "'${version}' is not a Warp version string"
  binary="$(binary_name "$channel")"

  archive="${ASDF_DOWNLOAD_PATH:-${install_path}/.download}/warp-tui-${channel}-$(host_os)-$(host_arch).tar.gz"
  [ -f "$archive" ] ||
    fail "archive not found: ${archive} (the download step did not run?)"

  bin_dir="${install_path}/bin"
  mkdir -p "$install_path" "$bin_dir"

  # The tarball already carries the layout we want -- the executable plus its
  # `resources/` sibling -- so it is extracted straight into the install
  # directory. Nothing has to be moved afterwards, which keeps the install
  # free of rename operations.
  echo "* Unpacking $(basename "$archive") into ${install_path}..."
  tar -xzf "$archive" -C "$install_path" ||
    fail "could not unpack ${archive}"

  [ -f "${install_path}/${binary}" ] ||
    fail "expected ${install_path}/${binary} after install"

  chmod +x "${install_path}/${binary}"
  _write_wrapper "$bin_dir" "$channel"

  # Marker so tooling can read the real version without shelling out.
  echo "$version" > "${install_path}/.warp-version"

  echo
  echo "warp ${version} installed ($(host_os)/$(host_arch), channel ${channel})."
  echo "  executable : ${install_path}/${binary}"
  echo "  CLI entry  : ${bin_dir}/${TOOL_NAME}  (shim it with: asdf reshim warp)"
}
