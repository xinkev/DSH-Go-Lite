#!/usr/bin/env bash
# Publish one built runtime as a GitHub release in xinkev/DSH-Go-Lite-Runtime.
#
#   runtime-release/publish-release.sh --dry-run runtime/out/arm64-v8a/assets/runtime
#   runtime-release/publish-release.sh runtime/out/arm64-v8a/assets/runtime [--latest]
#
# The first argument is the directory written by a RUNTIME_LAYERS=1 build
# (manifest.json + base-<abi>.tar.xz + engine-<abi>.tar.xz). This script:
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
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# {0,1}//'
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
BASE_FILE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["layers"]["base"]["file"])' "$STAGE/manifest.json")"
ENGINE_FILE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["layers"]["engine"]["file"])' "$STAGE/manifest.json")"
cp "$ARTIFACTS/$BASE_FILE" "$STAGE/$BASE_FILE"
cp "$ARTIFACTS/$ENGINE_FILE" "$STAGE/$ENGINE_FILE"

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
print("- Optional layers office/python: not shipped in this release")
if m.get("prunedModules"):
    print("- Pruned at build: " + ", ".join(sorted({x["name"] for x in m["prunedModules"]})))
print("- The app installs base + engine atomically and may reuse the same base for an engine-only update.")
PYEOF

FILES=("$STAGE/manifest.json" "$STAGE/$BASE_FILE" "$STAGE/$ENGINE_FILE" "$STAGE/SHA256SUMS")
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
