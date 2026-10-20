#!/usr/bin/env bash
#
# Install the Warp Agent CLI through asdf, using this plugin.
#
#   scripts/bootstrap.sh          install (or repair) everything
#   scripts/bootstrap.sh --check  only report what is missing
#
# The script is idempotent: run it again after a failed install, on a new
# machine, or to repair a half-finished asdf state.

set -euo pipefail

REPO_URL="${WARP_PLUGIN_REPO:-https://github.com/dehengxu/asdf-plugin-warp.git}"
PLUGIN_NAME="warp"
TOOL_NAME="warp"
CHECK_ONLY=0

for arg in "$@"; do
	case "$arg" in
	--check) CHECK_ONLY=1 ;;
	-h | --help)
		sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "unknown option: $arg" >&2
		exit 2
		;;
	esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    warning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[31m    error:\033[0m %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------- asdf ----
ASDF_BIN=""
for candidate in "${ASDF:-}" "$(command -v asdf 2>/dev/null || true)" "$HOME/.local/bin/asdf" "$HOME/.asdf/bin/asdf"; do
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then
		ASDF_BIN="$candidate"
		break
	fi
done
[ -n "$ASDF_BIN" ] || die "asdf not found; install it from https://asdf-vm.com/"

ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
export ASDF_DATA_DIR

# The Go rewrite (v0.16+) renamed a few subcommands: `asdf set -u` instead of
# `asdf global`, and `asdf list all` instead of `asdf list-all`.
if "$ASDF_BIN" set --help 2>&1 | grep -q -- "--home"; then
	ASDF_FLAVOUR="go"
else
	ASDF_FLAVOUR="classic"
fi
info "asdf: $ASDF_BIN ($ASDF_FLAVOUR), data dir $ASDF_DATA_DIR"

PLUGIN_DIR="$ASDF_DATA_DIR/plugins/$PLUGIN_NAME"
INSTALLS_DIR="$ASDF_DATA_DIR/installs/$PLUGIN_NAME"
LOCKS_DIR="$ASDF_DATA_DIR/install-locks/$PLUGIN_NAME"

# -------------------------------------------------------------- plugin ----
say "Plugin"
if [ ! -d "$PLUGIN_DIR" ]; then
	if [ "$CHECK_ONLY" -eq 1 ]; then
		info "MISSING: $PLUGIN_DIR"
	else
		info "adding $PLUGIN_NAME from $REPO_URL"
		if [ "$ASDF_FLAVOUR" = "go" ]; then
			"$ASDF_BIN" plugin add "dehengxu/$PLUGIN_NAME" >/dev/null
		else
			"$ASDF_BIN" plugin add "$PLUGIN_NAME" "$REPO_URL" >/dev/null
		fi
	fi
else
	# A leftover index.lock / config.lock makes every git operation in the
	# plugin directory fail, which in turn breaks `asdf plugin update`.
	for lock in index.lock config.lock; do
		if [ -f "$PLUGIN_DIR/.git/$lock" ]; then
			if [ "$CHECK_ONLY" -eq 1 ]; then
				info "stale lock: $PLUGIN_DIR/.git/$lock"
			else
				rm -f "$PLUGIN_DIR/.git/$lock"
				info "removed stale lock: $PLUGIN_DIR/.git/$lock"
			fi
		fi
	done

	if [ -d "$PLUGIN_DIR/.git" ]; then
		current_url="$(git -C "$PLUGIN_DIR" remote get-url origin 2>/dev/null || true)"
		if [ -z "$current_url" ]; then
			if [ "$CHECK_ONLY" -eq 1 ]; then
				info "no git remote configured for the plugin"
			else
				git -C "$PLUGIN_DIR" remote add origin "$REPO_URL"
				info "added git remote: $REPO_URL"
			fi
		elif [ "$current_url" != "$REPO_URL" ] && [ "${current_url%.git}" != "${REPO_URL%.git}" ]; then
			warn "plugin remote is $current_url, not $REPO_URL"
		fi

		if [ "$CHECK_ONLY" -eq 0 ]; then
			branch="${WARP_PLUGIN_BRANCH:-main}"
			if git -C "$PLUGIN_DIR" fetch --quiet origin 2>/dev/null; then
				# A plugin directory holds generated content, so it is safe to
				# throw local modifications away and follow origin/$branch.
				git -C "$PLUGIN_DIR" reset --hard "origin/$branch" >/dev/null &&
					info "plugin synced to origin/$branch" ||
					warn "could not sync the plugin to origin/$branch"
			else
				warn "could not fetch from origin"
			fi
		fi
	fi
	info "plugin dir: $PLUGIN_DIR"
fi

# ------------------------------------------------------- stale markers ----
# Go asdf records an in-progress install in
#   $ASDF_DATA_DIR/install-locks/<plugin>/<version>
# and deletes that marker when the install finishes. If the install was
# interrupted, or the shell was not allowed to delete files, the marker
# survives and asdf then reports a perfectly good installation as missing.
say "Stale install markers"
if [ -d "$LOCKS_DIR" ]; then
	for marker in "$LOCKS_DIR"/*; do
		[ -e "$marker" ] || continue
		version="$(basename "$marker")"
		if [ -d "$INSTALLS_DIR/$version" ]; then
			if [ "$CHECK_ONLY" -eq 1 ]; then
				info "STALE: $marker (the tool itself is installed)"
			else
				rm -f "$marker"
				info "removed $marker"
			fi
		else
			warn "marker for a version that is not installed: $marker"
		fi
	done
else
	info "none"
fi

# ----------------------------------------------------------- leftovers ----
# Older versions of this plugin staged the payload in .payload/ and moved it
# into place afterwards. The staging directory can survive an interrupted
# install and doubles the size of the installation.
say "Leftovers"
for version_dir in "$INSTALLS_DIR"/*/; do
	[ -d "$version_dir" ] || continue
	if [ -d "${version_dir}.payload" ]; then
		if [ "$CHECK_ONLY" -eq 1 ]; then
			info "leftover: ${version_dir}.payload"
		else
			rm -rf "${version_dir}.payload"
			info "removed ${version_dir}.payload"
		fi
	fi
done

# ------------------------------------------------------------- install ----
say "Install"
if [ "$CHECK_ONLY" -eq 1 ]; then
	info "would run: asdf install $TOOL_NAME latest"
	exit 0
fi

"$ASDF_BIN" install "$TOOL_NAME" latest

VERSION="$("$ASDF_BIN" latest "$TOOL_NAME" 2>/dev/null | tail -n 1)"
[ -n "$VERSION" ] || die "could not resolve the latest version"

say "Select version"
if [ "$ASDF_FLAVOUR" = "go" ]; then
	"$ASDF_BIN" set -u "$TOOL_NAME" "$VERSION"
else
	"$ASDF_BIN" global "$TOOL_NAME" "$VERSION"
fi
info "$TOOL_NAME $VERSION (global)"

say "Shim"
"$ASDF_BIN" reshim "$TOOL_NAME" "$VERSION"
info "shim: $("$ASDF_BIN" which "$TOOL_NAME" 2>/dev/null || echo "$ASDF_DATA_DIR/shims/$TOOL_NAME")"

say "Verify"
"$TOOL_NAME" --version

say "Done"
info "run 'warp' to log in; the CLI shares your account with the desktop app"
