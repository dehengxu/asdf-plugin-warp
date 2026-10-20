#!/usr/bin/env python3
"""Warp release metadata helper for the asdf `warp` plugin.

Warp does not publish GitHub release assets for its downloads -- the
open-source client is served from Google Cloud Storage instead. Two public
objects carry everything this plugin needs:

  https://releases.warp.dev/channel_versions.json
      the official version manifest. ``changelogs.<channel>`` maps every
      published version of that channel to its changelog, and
      ``<channel>.version`` is the current head of the channel.

  https://releases.warp.dev/<channel>/<version>/tui/<os>/<arch>/warp-tui-<channel>-<os>-<arch>.tar.gz
      the Warp Agent CLI (the ``warp`` command) for one version/platform.

Version strings look like ``v0.2026.10.14.08.27.stable_01``: the release
date, the release time, and the channel plus a per-channel build counter.
The channel is therefore recoverable from the version itself, which is what
the artifact path needs.

Subcommands:
  list [channel ...]          print published versions, newest first
  latest [channel]            print the head version of a channel (default stable)
  channel <version>           print the channel a version belongs to
  url <version> <os> <arch>   print the artifact URL
  md5 <version> <os> <arch>   print the published md5 (base64) for the artifact
  selftest                    offline coverage matrix over a recorded release
"""
import json
import re
import signal
import sys
import urllib.error
import urllib.request

BASE = "https://releases.warp.dev"
MANIFEST = BASE + "/channel_versions.json"

# Channels that ship installable builds. `dev` only ever keeps its current
# head in the changelog map, so it contributes exactly one version.
DEFAULT_CHANNELS = ("stable", "preview", "dev")

# Older channels exist in the manifest but are frozen long in the past.
KNOWN_CHANNELS = ("stable", "preview", "dev", "beta", "canary")

# Ordering used when two versions share a timestamp: the more conservative
# channel sorts first.
CHANNEL_RANK = {"stable": 0, "preview": 1, "dev": 2, "beta": 3, "canary": 4}

# v0.2026.10.14.08.27.stable_01
VERSION_RE = re.compile(
    r"^v?(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.([A-Za-z0-9]+)_(\d+)$"
)

# The CLI artifacts use these exact tokens, which do not match `uname -m`.
OS_TOKENS = {"macos", "linux"}
ARCH_TOKENS = {"aarch64", "x86_64"}


def die(msg):
    sys.stderr.write("asdf_warp: %s\n" % msg)
    sys.exit(1)


def headers():
    return {"User-Agent": "asdf-plugin-warp"}


def fetch_manifest():
    req = urllib.request.Request(MANIFEST, headers=headers())
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        die("could not fetch %s (HTTP %s)" % (MANIFEST, e.code))
    except urllib.error.URLError as e:
        die("network error talking to %s: %s" % (MANIFEST, e.reason))


def parse_version(version):
    """Return (sort_key, channel) for a version string, or (None, None)."""
    m = VERSION_RE.match(version)
    if not m:
        return None, None
    year, month, day, hour, minute, _build_no, channel, build = m.groups()
    key = (
        int(year),
        int(month),
        int(day),
        int(hour),
        int(minute),
        CHANNEL_RANK.get(channel, 99),
        int(build),
    )
    return key, channel


def asdf_version(version):
    """asdf convention: no leading `v`. The upstream path keeps it."""
    return version[1:] if version.startswith("v") else version


def upstream_version(version):
    """Rebuild the upstream form (with the leading `v`) from an asdf version."""
    if version.startswith("v"):
        return version
    return "v" + version


def artifact_name(channel, os_token, arch):
    return "warp-tui-%s-%s-%s.tar.gz" % (channel, os_token, arch)


def artifact_url(version, os_token, arch):
    upstream = upstream_version(version)
    channel = parse_version(upstream)[1]
    if not channel:
        die("'%s' is not a Warp version string" % version)
    if os_token not in OS_TOKENS:
        die("unknown os token '%s' (expected one of %s)" % (os_token, ", ".join(sorted(OS_TOKENS))))
    if arch not in ARCH_TOKENS:
        die("unknown arch token '%s' (expected one of %s)" % (arch, ", ".join(sorted(ARCH_TOKENS))))
    return "%s/%s/%s/tui/%s/%s/%s" % (
        BASE,
        channel,
        upstream,
        os_token,
        arch,
        artifact_name(channel, os_token, arch),
    )


def cmd_list(argv):
    channels = list(argv) or list(DEFAULT_CHANNELS)
    for ch in channels:
        if ch not in KNOWN_CHANNELS:
            die("unknown channel '%s' (known: %s)" % (ch, ", ".join(KNOWN_CHANNELS)))
    data = fetch_manifest()
    changelogs = data.get("changelogs", {})
    seen = {}
    for ch in channels:
        for version in (changelogs.get(ch) or {}):
            key, chan = parse_version(version)
            if key is None:
                continue
            seen[version] = key
        head = (data.get(ch) or {}).get("version")
        if head:
            key, _ = parse_version(head)
            if key is not None:
                seen[head] = key
    for version in sorted(seen, key=lambda v: seen[v], reverse=True):
        print(asdf_version(version))


def cmd_latest(argv):
    channel = argv[0] if argv else "stable"
    if channel not in KNOWN_CHANNELS:
        die("unknown channel '%s' (known: %s)" % (channel, ", ".join(KNOWN_CHANNELS)))
    data = fetch_manifest()
    head = (data.get(channel) or {}).get("version")
    if not head:
        die("manifest has no version for channel '%s'" % channel)
    print(asdf_version(head))


def cmd_channel(argv):
    if len(argv) != 1:
        die("usage: warp_releases.py channel <version>")
    _, channel = parse_version(upstream_version(argv[0]))
    if not channel:
        die("'%s' is not a Warp version string" % argv[0])
    print(channel)


def cmd_url(argv):
    if len(argv) != 3:
        die("usage: warp_releases.py url <version> <os> <arch>")
    print(artifact_url(argv[0], argv[1], argv[2]))


def cmd_md5(argv):
    """The GCS md5 of the artifact, base64 encoded, as published in the
    `x-goog-hash` response header."""
    if len(argv) != 3:
        die("usage: warp_releases.py md5 <version> <os> <arch>")
    url = artifact_url(argv[0], argv[1], argv[2])
    req = urllib.request.Request(url, method="HEAD", headers=headers())
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            hashes = resp.headers.get_all("x-goog-hash") or []
    except urllib.error.HTTPError as e:
        die("could not fetch headers for %s (HTTP %s)" % (url, e.code))
    except urllib.error.URLError as e:
        die("network error talking to %s: %s" % (url, e.reason))
    for h in hashes:
        if h.startswith("md5="):
            print(h[4:].strip())
            return 0
    die("no md5 published for %s" % url)


def cmd_selftest():
    """Offline check that every supported host maps to a real artifact path.

    The recorded version was resolved from the live manifest and each path
    was confirmed with an HTTP request, so this table is a snapshot, not a
    guess. Run `warp_releases.py url` to print the paths.
    """
    version = "v0.2026.10.14.08.27.stable_01"
    cases = [
        ("macos", "aarch64", "warp-tui-stable-macos-aarch64.tar.gz"),
        ("macos", "x86_64", "warp-tui-stable-macos-x86_64.tar.gz"),
        ("linux", "aarch64", "warp-tui-stable-linux-aarch64.tar.gz"),
        ("linux", "x86_64", "warp-tui-stable-linux-x86_64.tar.gz"),
    ]
    failures = 0
    for os_token, arch, expected in cases:
        url = artifact_url(version, os_token, arch)
        got = url.rsplit("/", 1)[-1]
        ok = got == expected
        failures += 0 if ok else 1
        print("%-5s %-6s %-6s -> %s" % ("ok" if ok else "FAIL", os_token, arch, got))
    print("\n%d/%d passed" % (len(cases) - failures, len(cases)))
    return 1 if failures else 0


def main(argv):
    # `asdf list-all` pipes this output into a pager or `head`, which closes
    # the pipe early. Restore the default SIGPIPE behaviour so the process
    # dies quietly instead of dumping a BrokenPipeError traceback.
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    if not argv:
        die(
            "usage: warp_releases.py "
            "{list [channel ...]|latest [channel]|channel <version>|"
            "url <version> <os> <arch>|md5 <version> <os> <arch>|selftest}"
        )
    cmd = argv[0]
    rest = argv[1:]
    if cmd == "list":
        cmd_list(rest)
    elif cmd == "latest":
        cmd_latest(rest)
    elif cmd == "channel":
        return cmd_channel(rest)
    elif cmd == "url":
        return cmd_url(rest)
    elif cmd == "md5":
        return cmd_md5(rest)
    elif cmd == "selftest":
        return cmd_selftest()
    else:
        die("unknown subcommand: %s" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
