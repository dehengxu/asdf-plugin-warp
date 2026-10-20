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

`asdf list-all warp` prints every published version, newest first, across the
`stable`, `preview` and `dev` channels. Narrow it with a channel name:

```bash
asdf list-all warp stable
```

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
asdf plugin add dehengxu/asdf-plugin-warp
asdf install warp latest
asdf global warp <version>     # or: asdf set -u warp <version>
asdf reshim warp
warp --version
```

The CLI shares your Warp account with the desktop app. Run `warp` once and
follow the login link it prints.

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
