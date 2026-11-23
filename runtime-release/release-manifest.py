#!/usr/bin/env python3
"""Rewrite a built runtime manifest into the shape the app fetches from a GitHub release.

The release manifest describes one install unit: base + engine are separate files for
resumable downloads and base reuse, but the app installs them all-or-nothing. Optional
layers (office, python) are declared as placeholders and carry no file until they ship.

Usage:
  release-manifest.py --artifacts runtime/out/arm64-v8a/assets/runtime --out manifest.json

Reads <artifacts>/manifest.json (the build manifest) and verifies the sha256 and byte size of
every layer file in <artifacts> before writing. Exits non-zero on any mismatch so publishing
cannot upload a manifest that disagrees with its archives.
"""
import argparse
import hashlib
import json
import os
import re
import sys

OPTIONAL_LAYERS = {
    "office": "Office document conversion (libreoffice-kit-wasm); downloaded only when enabled",
    "python": "Bundled Python 3 for user scripts; not shipped yet",
}
REQUIRED_LAYERS = ("base", "engine")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load(path):
    with open(path, "rb") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True,
                    help="runtime/out/<abi>/assets/runtime from a RUNTIME_LAYERS=1 build")
    ap.add_argument("--abi", help="required ABI (default: read from the build manifest)")
    ap.add_argument("--out", required=True, help="write the release manifest here")
    args = ap.parse_args()

    artifacts = os.path.abspath(args.artifacts)
    built_path = os.path.join(artifacts, "manifest.json")
    if not os.path.isfile(built_path):
        raise SystemExit("missing build manifest: " + built_path)
    built = load(built_path)

    if built.get("schema") != 2 or "layers" not in built:
        raise SystemExit("build manifest is not layered (need RUNTIME_LAYERS=1, schema 2): " + built_path)
    abi = built.get("abi")
    if args.abi and args.abi != abi:
        raise SystemExit("build manifest ABI is %s, not %s" % (abi, args.abi))
    if abi not in ("arm64-v8a", "x86_64"):
        raise SystemExit("unsupported ABI in build manifest: %r" % (abi,))

    version = built.get("runtimeVersion") or ""
    match = re.match(r"^(r[0-9]+)-", version)
    if not match:
        raise SystemExit("runtimeVersion does not start with a runtime major (rNN): %r" % version)
    runtime_major = match.group(1)

    extra = set(built["layers"]) - set(REQUIRED_LAYERS) - set(OPTIONAL_LAYERS)
    if not set(REQUIRED_LAYERS) <= set(built["layers"]) or extra:
        raise SystemExit("build manifest must carry base and engine plus optional layers %s, not %s"
                         % (sorted(OPTIONAL_LAYERS), sorted(extra)))

    total = 0
    layers = {}
    for kind in REQUIRED_LAYERS:
        layer = built["layers"][kind]
        name = layer.get("asset")
        if not name or os.path.basename(name) != name:
            raise SystemExit("invalid %s layer file name: %r" % (kind, name))
        expected = layer.get("sha256")
        size = layer.get("bytes")
        path = os.path.join(artifacts, name)
        if not os.path.isfile(path):
            raise SystemExit("missing %s layer: %s" % (kind, path))
        actual = sha256_file(path)
        actual_size = os.path.getsize(path)
        if actual != expected or actual_size != size:
            raise SystemExit("%s layer does not match the build manifest (%s: sha256 %s/%s, "
                             "bytes %s/%s)" % (kind, name, actual, expected, actual_size, size))
        layers[kind] = {
            "file": name,
            "sha256": actual,
            "bytes": actual_size,
            "tarSha256": layer.get("tarSha256"),
            "uncompressedBytes": layer.get("uncompressedBytes"),
            "role": "required",
        }
        total += actual_size

    for kind, note in OPTIONAL_LAYERS.items():
        layer = built["layers"].get(kind)
        if layer is None:
            layers[kind] = {
                "file": None,
                "sha256": None,
                "bytes": 0,
                "tarSha256": None,
                "uncompressedBytes": 0,
                "role": "optional",
                "available": False,
                "note": note,
            }
            continue
        name = layer.get("asset")
        if not name or os.path.basename(name) != name:
            raise SystemExit("invalid %s layer file name: %r" % (kind, name))
        path = os.path.join(artifacts, name)
        if not os.path.isfile(path):
            raise SystemExit("missing %s layer: %s" % (kind, path))
        actual = sha256_file(path)
        actual_size = os.path.getsize(path)
        if actual != layer.get("sha256") or actual_size != layer.get("bytes"):
            raise SystemExit("%s layer does not match the build manifest (%s: sha256 %s/%s, "
                             "bytes %s/%s)" % (kind, name, actual, layer.get("sha256"),
                                               actual_size, layer.get("bytes")))
        layers[kind] = {
            "file": name,
            "sha256": actual,
            "bytes": actual_size,
            "tarSha256": layer.get("tarSha256"),
            "uncompressedBytes": layer.get("uncompressedBytes"),
            "role": "optional",
            "available": True,
            "installsInto": layer.get("installsInto"),
            "requires": layer.get("requires") or list(REQUIRED_LAYERS),
            "paths": layer.get("paths") or [],
            "note": note,
        }

    release = {
        "schema": 2,
        "runtimeVersion": version,
        "tag": version,
        "abi": abi,
        "installUnit": {
            "name": "dsh-runtime-%s" % abi,
            "atomic": True,
            "requiredLayers": ["base", "engine"],
            "reuseInstalledBase": True,
            "totalBytes": total,
        },
        "totalBytes": total,
        "layers": layers,
        "baseCompatibility": built.get("baseCompatibility"),
        "upgrade": built.get("upgrade"),
        "components": {
            "dshVersion": built.get("dshVersion"),
            "nodeVersion": built.get("nodeVersion"),
            "pnpmVersion": built.get("pnpmVersion"),
            "ubuntuVersion": built.get("ubuntuVersion"),
            "prootVersion": built.get("prootVersion"),
        },
        "prunedModules": built.get("prunedModules") or [],
        "compatibility": {
            "minAppSchema": 2,
            "runtimeMajor": runtime_major,
            "note": "Installing app needs manifest schema >= minAppSchema and must pin runtimeMajor; "
                    "baseCompatibility.baseId identifies a base the app may reuse for an engine-only update.",
        },
        "files": ["manifest.json"] + [layers[kind]["file"] for kind in REQUIRED_LAYERS]
                 + [l["file"] for l in layers.values() if l["role"] == "optional" and l["available"]]
                 + ["SHA256SUMS"],
    }

    with open(args.out + ".tmp", "w") as f:
        json.dump(release, f, indent=2)
        f.write("\n")
    os.replace(args.out + ".tmp", args.out)
    print("%s %s (%s): %.1f MiB required, optional: %s" % (
        version, abi, runtime_major, total / 2**20,
        ", ".join("%s %.1f MiB" % (kind, layers[kind]["bytes"] / 2**20)
                  for kind in OPTIONAL_LAYERS if layers[kind]["available"]) or "none"))


if __name__ == "__main__":
    main()
