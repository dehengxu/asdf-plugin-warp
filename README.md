# asdf-plugin-warp

An [asdf](https://asdf-community.com/) plugin for the **Warp Agent CLI** — the
`warp` command that runs Warp's coding agent in any terminal.

## Why this plugin exists

Warp is now open source (`warpdotdev/warp`, AGPL v3), but its **downloads do not
go through GitHub Releases**. The published artifacts live on Google Cloud
Storage:

```
https://releases.warp.dev/<channel>/<version>/tui/<os>/<arch>/warp-tui-<channel>-<os>-<arch>.tar.gz
```

GitHub Releases for the repo carry **no assets at all** — a release there is a
version marker, not a download. So the usual "list tags → fetch a release
asset → check its sha256" plugin shape does not apply, and there is no
community plugin for Warp either.

Two public objects carry everything this plugin needs:

| Object | Purpose |
|---|---|
| `https://releases.warp.dev/channel_versions.json` | the official version manifest. `changelogs.<channel>` maps every published version of that channel to its changelog; `<channel>.version` is the current head |
| `https://releases.warp.dev/<channel>/<version>/tui/...` | the CLI tarball for one version and platform |

The version list therefore comes from Warp itself, not from a tag list that
could drift.

## Integrity checking

Google Cloud Storage publishes an md5 and a crc32c for every object, but the
digest covers the **stored** object, which Warp uploads with
`Content-Encoding: gzip`. A client that does not ask for gzip is served the
**transparently decompressed** bytes instead, so the published digest covers a
different byte sequence than the one that lands on disk — the two legitimately
disagree even for a pristine download:

```
x-goog-stored-content-encoding: gzip
x-goog-stored-content-length:   84738430     <- the stored (compressed) size
```

The plugin therefore:

1. compares the received file against the published md5 and **reports a
   mismatch as a warning**, not a failure, with an explanation;
2. gates the install on `gzip -t`, which checks the CRC32 the gzip trailer
   stores over the whole uncompressed tar. That is the authoritative check for
   the bytes actually received, and it catches a truncated or corrupted
   download;
3. confirms the tarball really contains the expected executable and
   `resources/` directory before the install is allowed to finish.

A download whose gzip CRC does not check out is rejected outright.

## Supported platforms

| Host | `uname -m` | artifact | channel in the name |
|---|---|---|---|
| macOS | `arm64` | `warp-tui-<ch>-macos-aarch64.tar.gz` | `stable` / `preview` / `dev` |
| macOS | `x86_64` | `warp-tui-<ch>-macos-x86_64.tar.gz` | as above |
| Linux | `aarch64` | `warp-tui-<ch>-linux-aarch64.tar.gz` | as above |
| Linux | `x86_64` | `warp-tui-<ch>-linux-x86_64.tar.gz` | as above |

Windows is not supported: Warp does not publish a TUI build for it.

Note the artifact tokens are `aarch64` / `x86_64`, which do **not** match
`uname -m` (`arm64` / `x86_64`). The plugin translates, and it asks the
*hardware* rather than the process about Apple Silicon — under Rosetta 2
`uname -m` answers `x86_64` even on an arm64 Mac, which would install the
wrong build.

## Version strings

```
0.2026.10.14.08.27.stable_01
└─ release date ──┘ └ time ┘ └ channel ┘ └ build ┘
```

The channel is part of the version, so the same string is enough to build the
download path. The `v` prefix that Warp uses upstream is dropped for asdf
(its convention) and restored when the URL is built.

`asdf list all warp` prints every published version, newest first, across the
`stable`, `preview` and `dev` channels. Narrow it with a channel name:

```bash
asdf list all warp stable
```

> The Go rewrite of asdf (v0.16+) renamed a few subcommands. Use `asdf list all
> warp` there; the classic bash asdf spells it `asdf list-all warp`.

## Install layout

```
~/.asdf/installs/warp/<version>/
├── warp-tui-<channel>      the executable, named by Warp upstream
├── resources/              settings schema, bundled skills, licences
└── bin/warp                the shim target
```

The executable keeps Warp's own name because the release channel is baked into
it. The shim is a **wrapper script**, never a symlink: the CLI resolves its
`resources/` directory relative to the real executable path, and `exec`ing
through a symlink would make `process.execPath` point at the shim and the
resources would go missing.

## Usage

```bash
asdf plugin add warp https://github.com/dehengxu/asdf-plugin-warp.git
asdf install warp latest
asdf set -u warp <version>     # global; classic asdf: asdf global warp <version>
asdf reshim warp
warp --version
```

> Warp is not in the official asdf plugin index, so the repository URL has to
> be spelled out — `asdf plugin add warp` alone would fail. The plugin *name*
> is still just `warp`, and asdf only accepts lower-case names without a
> slash, so `asdf plugin add dehengxu/asdf-plugin-warp` is not valid either.

> Go asdf (v0.16+) spells the global setter `asdf set -u`; the classic bash
> asdf spells it `asdf global`.

## Install in one command

`scripts/bootstrap.sh` registers the plugin, repairs a half-finished asdf
state and installs the CLI:

```bash
scripts/bootstrap.sh            # install, or repair an existing install
scripts/bootstrap.sh --check    # only report what is missing
```

It is idempotent, so it is safe to run again on a new machine or after a
failed install. Among other things it clears stale install markers (see
below), removes the leftovers of an interrupted extraction, and drops the
`index.lock` / `config.lock` files that would otherwise break
`asdf plugin update`.

The CLI shares your Warp account with the desktop app. Run `warp` once and
follow the login link it prints.

## Troubleshooting: "No compatible versions installed"

The Go rewrite of asdf tracks an install with a **marker file**:

```
~/.asdf/install-locks/<plugin>/<version>
```

`asdf install` creates that marker before it runs the plugin and deletes it
afterwards. If the process is interrupted — or if the shell that ran it was
not allowed to delete files — the marker survives, and asdf then reports the
version as *not* installed even though the files are all there:

```
$ asdf list warp
No compatible versions installed (warp)
$ asdf current warp
warp  0.2026.10.14.08.27.stable_01  ~/.tool-versions  false
```

The command still works — the shim resolves the version from
`.tool-versions` and never consults the marker — but `asdf list`, `asdf where`
and `asdf current` keep claiming the tool is missing. Clearing the stale
marker puts asdf's bookkeeping back in order:

```bash
rm ~/.asdf/install-locks/warp/<version>
asdf reshim warp
```

Note that `asdf install` needs **delete permission** on
`~/.asdf/install-locks/` to finish cleanly. In a sandbox that forbids
unlinking files, an install always ends with the marker still in place, even
though the tool itself was unpacked correctly.

## The desktop app is not installed by this plugin

`Warp.app` is a GUI application bundle shipped as a `.dmg`. Putting a bundle
under asdf means mounting a disk image, and a GUI app is not what asdf's
shim-and-version model is for. Install it the way Warp documents:

- macOS: `brew install --cask warp` (or the download page)
- The Warp Agent CLI installed by this plugin is the same agent, running in
  your existing terminal.

If you want the app under asdf anyway, `lib/install-macos-app.sh` mounts the
matching `.dmg` and copies `Warp.app` into the active asdf install directory.
It needs a normal (non-sandboxed) shell, because mounting a disk image is a
privileged operation.

## Development

```bash
lib/warp_releases.py selftest     # offline coverage matrix
lib/warp_releases.py list stable  # live version list
lib/warp_releases.py url 0.2026.10.14.08.27.stable_01 macos aarch64
```
