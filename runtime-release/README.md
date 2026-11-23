# DSH Go Lite runtime releases

Release assets for the Linux runtime that the dsh-Go Android app downloads on first run.
The app APK does not contain the runtime; this repository does.

## What this repository holds

Only release assets and the scripts that publish them. Every release is a git tag whose name
is the runtime version, with these files attached:

| File | Required | Content |
| --- | --- | --- |
| `manifest.json` | yes | Release-shaped manifest the app fetches (see below) |
| `base-arm64-v8a.tar.xz` | yes | Ubuntu Base + Node.js + bundled Python + proot support files |
| `engine-arm64-v8a.tar.xz` | yes | DSH npm tree (without office), patches, dsh-go bridge, pnpm, launch overlay |
| `office-arm64-v8a.tar.xz` | no | `@deepseek-ai/libreoffice-kit-wasm` incl. `assets/soffice.wasm` + `soffice.data` |
| `SHA256SUMS` | yes | sha256 of every other attached file |

`manifest.json` here is **not** the build manifest in the dsh-Go checkout; it is rewritten by
`release-manifest.py` into the contract below.

Base and engine are two files but **one install unit**: two files make the download resumable
and let an engine-only update reuse an already installed base. The app installs both
all-or-nothing. Office is an optional third file, installed on top of that unit only when the
user asks for office support.

## Versioning

The runtime version is produced by `runtime/build-runtime.sh`:

```
r<major>-dsh<dsh>-node<node>-ubuntu<ubuntu>-<12-hex inputs sha>
r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-1a2b3c4d5e6f
```

- The tag is exactly `runtimeVersion`. Never reuse or republish a tag: the app caches by tag
  and verifies by sha256.
- `rNN` is the runtime major. Bump it only for a layout or contract change the app must branch
  on (archive layout, launch template, install paths). R15 is the current major.
- The inputs hash changes when any pinned input, the build recipe, the patch set, or
  `RUNTIME_PRUNE` changes, so a normal rebuild yields a new version.
- Publish in version order. `--latest` marks the release as the first-run default; do not use
  it for an out-of-order backfill.

## Release manifest

`release-manifest.py` writes this shape. Field names are the app contract.

```json
{
  "schema": 2,
  "runtimeVersion": "r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-1a2b3c4d5e6f",
  "tag": "r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-1a2b3c4d5e6f",
  "abi": "arm64-v8a",
  "installUnit": {
    "name": "dsh-runtime-arm64-v8a",
    "atomic": true,
    "requiredLayers": ["base", "engine"],
    "reuseInstalledBase": true,
    "totalBytes": 120000000
  },
  "totalBytes": 120000000,
  "layers": {
    "base": {"file": "base-arm64-v8a.tar.xz", "sha256": "…", "bytes": 50000000,
             "tarSha256": "…", "uncompressedBytes": 90000000, "role": "required"},
    "engine": {"file": "engine-arm64-v8a.tar.xz", "sha256": "…", "bytes": 70000000,
               "tarSha256": "…", "uncompressedBytes": 200000000, "role": "required"},
    "office": {"file": "office-arm64-v8a.tar.xz", "sha256": "…", "bytes": 45000000,
               "tarSha256": "…", "uncompressedBytes": 145000000, "role": "optional",
               "available": true, "installsInto": "/opt/dsh",
               "requires": ["base", "engine"],
               "paths": ["/opt/dsh/node_modules/@deepseek-ai/libreoffice-kit-wasm"]},
    "python": {"file": null, "sha256": null, "bytes": 0, "tarSha256": null,
               "uncompressedBytes": 0, "role": "optional", "available": false,
               "note": "not shipped yet"}
  },
  "baseCompatibility": {"schema": 1, "osRelease": {"…": "…"}, "python3Sha256": "…"},
  "upgrade": {"schema": 1, "baseId": "…", "paths": ["opt/dsh", "opt/node", "…"]},
  "components": {"dshVersion": "…", "nodeVersion": "…", "pnpmVersion": "…",
                 "ubuntuVersion": "…", "prootVersion": "…"},
  "prunedModules": [{"name": "sherpa", "packages": ["node_modules/sherpa-onnx-linux-arm64"], "bytes": 1}],
  "compatibility": {"minAppSchema": 2, "runtimeMajor": "r15", "note": "…"},
  "files": ["manifest.json", "base-arm64-v8a.tar.xz", "engine-arm64-v8a.tar.xz",
            "office-arm64-v8a.tar.xz", "SHA256SUMS"]
}
```

Rules:

- `totalBytes` is the size of required layers only; show one install action from it.
- `role: "required"` layers must all be fetched and verified before anything is installed.
  Today that is base + engine.
- Office is `role: "optional"`: fetch and install it only when the user enables office. It
  needs base + engine installed first, installs into the same DSH prefix, and replaces only
  the paths listed in `paths`. The engine archive does not contain the office package.
- An optional layer with `available: false` has no file; ignore it. `python` is only a
  placeholder today.
- `prunedModules` says which optional engine modules the build removed (`sherpa`; speech is
  not part of the product). Office is not pruned, it is split into its own layer.

## Compatibility rule

The app pins two constants:

- a minimum manifest schema (`2` today) — reject releases whose `schema` is lower;
- a runtime major (`r15` today) — reject releases with a different
  `compatibility.runtimeMajor`.

An app that accepts an older runtime major must implement that major's install layout
explicitly; do not guess from field presence.

Base reuse is keyed by `upgrade.baseId` / `baseCompatibility`: when an installed base has the
same `baseId`, an engine-only update may download and apply just the engine layer. Any other
change, or any doubt, reinstalls both required layers atomically.

## Publishing a release

Build with layers (about 10 minutes in an x86_64 Linux container; no device required):

```bash
RUNTIME_LAYERS=1 python3 -I runtime/build-runtime.sh arm64-v8a
# artifacts: runtime/out/arm64-v8a/assets/runtime/
```

Dry-run first, then publish:

```bash
runtime-release/publish-release.sh --dry-run runtime/out/arm64-v8a/assets/runtime
runtime-release/publish-release.sh runtime/out/arm64-v8a/assets/runtime
# first-run default: add --latest (publish in version order)
```

The script runs, with no credentials stored in it:

```bash
gh release create "<runtimeVersion>" --repo xinkev/DSH-Go-Lite-Runtime --title "Runtime <runtimeVersion>" \
  --notes-file "<staging>/RELEASE_NOTES.md" \
  "<staging>/manifest.json" "<staging>/base-arm64-v8a.tar.xz" \
  "<staging>/engine-arm64-v8a.tar.xz" "<staging>/office-arm64-v8a.tar.xz" \
  "<staging>/SHA256SUMS"
```

`gh` reads its own login or `GH_TOKEN`; the script never commits, pushes, or creates the repo.
Office is uploaded only when the build produced it (the script reads `files` from the generated
manifest).

### One-time repository bootstrap

Run these once, from the dsh-Go checkout, if the repository does not exist yet:

```bash
mkdir -p ~/projects/dsh-go-lite-runtime
cp -R runtime-release/. ~/projects/dsh-go-lite-runtime/
cd ~/projects/dsh-go-lite-runtime
git init -b main
git add README.md publish-release.sh release-manifest.py
git commit -m "runtime: scaffold the release repo"
gh repo create xinkev/DSH-Go-Lite-Runtime --public --source=. --remote=origin --push
```

## Expected app flow

1. Resolve the release (latest, or a pinned `runtimeVersion`), download `manifest.json`.
2. Check `schema` and `compatibility.runtimeMajor`; refuse with a stable error code otherwise.
3. If no runtime is installed: download `installUnit.requiredLayers` into a staging directory,
   verify each sha256 and byte size, then extract base then engine into the final rootfs.
   All-or-nothing; leave the previous runtime untouched on failure.
4. If a runtime is installed and `upgrade.baseId` matches: download only the engine layer,
   verify it, then apply it over the existing base.
5. Show one progress item for the install unit (`totalBytes`), plus per-layer progress.
6. If the user enables office, fetch `layers.office` only after base + engine are installed,
   verify it, and extract it over the DSH prefix. A failed office install must leave the
   runtime usable.
7. Keep user state outside `upgrade.paths`; those are the only paths an engine update replaces.

## Open contract points (not decided by this repo)

- Exact GitHub API vs. fixed `releases/latest/download/manifest.json` URL, and rate-limit
  fallback.
- Staging/install directory names on device and the rename strategy that makes the install
  atomic.
- Free-space check: `bytes` is compressed, `uncompressedBytes` is what the rootfs needs.
- Uninstalling or re-downloading an optional layer, and whether office can update without a
  runtime update.
- Error codes for schema/major mismatch, checksum mismatch, truncated download, and
  out-of-space.
- Provenance beyond `SHA256SUMS`: the sums come from the same release and are not signed.
