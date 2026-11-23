#!/usr/bin/env bash
# Publish one built runtime as a GitHub release in xinkev/DSH-Go-Lite-Runtime.
#
#   runtime-release/publish-release.sh --dry-run runtime/out/arm64-v8a/assets/runtime
#   runtime-release/publish-release.sh runtime/out/arm64-v8a/assets/runtime [--latest]
#
# The first argument is the directory written by a RUNTIME_LAYERS=1 build
# (manifest.json + base/engine/office-<abi>.tar.xz). This script:
#   1. rewrites the build manifest into the release shape the app fetches,
#   2. verifies every uploaded file's sha256 against the build manifest,
#   3. writes SHA256SUMS and release notes,
#   4. calls gh release create with the runtimeVersion as the tag.
#
# It never stores credentials: gh reads GH_TOKEN or its own keyring. It does not commit,
# push a branch, or create the repository.
set -euo pipefail

HERE="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${RUNTIME_RELEASE_REPO:-xinkev/DSH-Go-Lite-Runtime}"
ARTIFACTS=""
DRY_RUN=0
LATEST=0

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# //'
}

die() { printf 'publish-release: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --latest) LATEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$ARTIFACTS" ]] || die "only one artifacts directory is accepted"
       ARTIFACTS="$1"; shift ;;
  esac
done

ARTIFACTS="${ARTIFACTS:-$HERE/../runtime/out/arm64-v8a/assets/runtime}"
[[ -d "$ARTIFACTS" ]] || die "artifacts directory not found: $ARTIFACTS"
for tool in gh python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
gh auth status --hostname github.com >/dev/null 2>&1 \
  || die "gh is not authenticated for github.com; run gh auth login (or set GH_TOKEN)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Release-shaped manifest; this also verifies the layer files against the build manifest.
python3 -I "$HERE/release-manifest.py" --artifacts "$ARTIFACTS" --out "$STAGE/manifest.json" >&2
VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtimeVersion"])' "$STAGE/manifest.json")"
LAYER_FILES=()
while IFS= read -r name; do
  LAYER_FILES+=("$name")
  cp "$ARTIFACTS/$name" "$STAGE/$name"
done < <(python3 -I - "$STAGE/manifest.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
for name in m["files"]:
    if name not in ("manifest.json", "SHA256SUMS"):
        print(name)
PYEOF
)

# SHA256SUMS covers every uploaded asset except itself, sorted by file name.
( cd "$STAGE" && python3 -I - <<'PYEOF'
import hashlib, os
rows = []
for name in sorted(os.listdir(".")):
    if name == "SHA256SUMS" or not os.path.isfile(name):
        continue
    digest = hashlib.sha256()
    with open(name, "rb") as f:
        while chunk := f.read(1024 * 1024):
            digest.update(chunk)
    rows.append("%s  %s\n" % (digest.hexdigest(), name))
with open("SHA256SUMS", "w") as f:
    f.writelines(rows)
PYEOF
)

python3 -I - "$STAGE/manifest.json" > "$STAGE/RELEASE_NOTES.md" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
unit = m["installUnit"]
print("# Runtime " + m["runtimeVersion"])
print()
print("- ABI: " + m["abi"])
print("- Runtime major: " + m["compatibility"]["runtimeMajor"])
print("- DSH %s, Node %s, pnpm %s, Ubuntu %s" % (
    m["components"]["dshVersion"], m["components"]["nodeVersion"],
    m["components"]["pnpmVersion"], m["components"]["ubuntuVersion"]))
print("- Install unit: %s (%d files, %.1f MiB compressed)" % (
    unit["name"], len(unit["requiredLayers"]), unit["totalBytes"] / 2**20))
for kind in unit["requiredLayers"]:
    layer = m["layers"][kind]
    print("  - %s: %s, %.1f MiB" % (kind, layer["file"], layer["bytes"] / 2**20))
for kind, layer in m["layers"].items():
    if layer["role"] != "optional":
        continue
    if layer["available"]:
        print("  - %s (optional, installs into %s): %s, %.1f MiB" % (
            kind, layer["installsInto"], layer["file"], layer["bytes"] / 2**20))
    else:
        print("  - %s (optional): not shipped in this release" % kind)
if m.get("prunedModules"):
    print("- Pruned at build: " + ", ".join(sorted({x["name"] for x in m["prunedModules"]})))
print("- The app installs base + engine atomically and may reuse the same base for an engine-only update.")
PYEOF

FILES=("$STAGE/manifest.json")
for name in "${LAYER_FILES[@]}"; do FILES+=("$STAGE/$name"); done
FILES+=("$STAGE/SHA256SUMS")
CMD=(gh release create "$VERSION" --repo "$REPO" --title "Runtime $VERSION"
     --notes-file "$STAGE/RELEASE_NOTES.md")
[[ "$LATEST" == 1 ]] && CMD+=(--latest)
CMD+=("${FILES[@]}")

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'dry run: would publish %s to %s\n  ' "$VERSION" "$REPO"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  die "release $VERSION already exists; runtime versions are immutable and never republished"
fi
"${CMD[@]}"
printf 'published %s to %s\n' "$VERSION" "$REPO"
