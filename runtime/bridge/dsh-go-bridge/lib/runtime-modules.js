// Optional runtime modules: the office layer today, python later.
//
// The release manifest (runtime-release/README.md in the dsh-Go checkout) is the only
// network input. It names the archive, its digest and the guest paths the layer owns;
// this module fetches, verifies, unpacks and swaps exactly those paths, then records the
// install where the app also looks for it (/opt/dsh/runtime/optional/<name>.json).
//
// All-or-nothing: the archive is downloaded and verified in a temp directory under the
// runtime root, unpacked into a staging directory, and only then moved into place. A
// failed install leaves the runtime as it was and removes every temporary file.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  createWriteStream, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync,
} from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/** Prompt section name; the tools themselves need no namespace. */
export const SECTION = "dsh-go-runtime-modules";
/** The same fixed entry the app's installer reads (RuntimeRelease.DEFAULT_MANIFEST_URL). */
export const DEFAULT_MANIFEST_URL =
  "https://github.com/xinkev/DSH-Go-Lite-Runtime/releases/latest/download/manifest.json";
export const DEFAULT_ROOT = "/opt/dsh";
const MANIFEST_TTL_MS = 10 * 60 * 1000;
const MODULE_NAME = /^[a-z][a-z0-9_-]{0,63}$/;
const DIGEST = /^[0-9a-f]{64}$/;
const DOWNLOAD_TIMEOUT_MS = 10 * 60 * 1000;

/** A refusal with a stable code; the message is what the model reads. */
export class RuntimeModuleError extends Error {
  constructor(code, message) {
    super(message + " [" + code + "]");
    this.code = code;
  }
}

const isObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value) => (typeof value === "string" ? value : "");
const mib = (bytes) => Math.max(1, Math.round(bytes / (1024 * 1024))) + " MiB";

export function manifestUrlOf(env = process.env) {
  return env.DSH_GO_RUNTIME_MANIFEST_URL?.trim() || DEFAULT_MANIFEST_URL;
}

export function rootOf(env = process.env) {
  return env.DSH_GO_RUNTIME_ROOT?.trim() || DEFAULT_ROOT;
}

/** Layer archives sit next to the manifest: releases/latest/download/<file>. */
export function layerUrl(manifestUrl, file) {
  return manifestUrl.slice(0, manifestUrl.lastIndexOf("/") + 1) + file;
}

/**
 * Validate the release manifest and return its optional layers. The app validates the
 * same fields (RuntimeRelease.kt); this parser only reads what an install needs and
 * refuses anything it would have to guess about.
 */
export function parseManifest(text) {
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new RuntimeModuleError("module_manifest", "the runtime release manifest is not JSON");
  }
  if (!isObject(json) || !isObject(json.layers)) {
    throw new RuntimeModuleError("module_manifest", "the runtime release manifest has no layers");
  }
  const version = str(json.runtimeVersion).trim();
  const layers = {};
  for (const [name, layer] of Object.entries(json.layers)) {
    if (!isObject(layer) || layer.role !== "optional") continue;
    if (!MODULE_NAME.test(name)) continue;
    const available = layer.available === true;
    const note = str(layer.description) || str(layer.note) || undefined;
    if (!available) {
      layers[name] = { name, available: false, description: note || name + ": optional runtime module, not shipped yet" };
      continue;
    }
    const file = str(layer.file);
    const sha256 = str(layer.sha256);
    const bytes = Number(layer.bytes);
    const installsInto = str(layer.installsInto).replace(/\/+$/, "");
    const paths = Array.isArray(layer.paths) ? layer.paths.filter((path) => typeof path === "string").map((path) => path.replace(/\/+$/, "")) : [];
    if (!/^[A-Za-z0-9._-]+$/.test(file) || !(file.endsWith(".tar.xz") || file.endsWith(".tar.gz"))) {
      throw new RuntimeModuleError("module_manifest", "optional layer '" + name + "' has an invalid archive name");
    }
    if (!DIGEST.test(sha256) || !Number.isSafeInteger(bytes) || bytes <= 0) {
      throw new RuntimeModuleError("module_manifest", "optional layer '" + name + "' has no usable digest or size");
    }
    if (!installsInto.startsWith("/") || installsInto === "/" || installsInto.includes("..")) {
      throw new RuntimeModuleError("module_manifest", "optional layer '" + name + "' has no valid installsInto");
    }
    if (paths.length === 0) {
      throw new RuntimeModuleError("module_manifest", "optional layer '" + name + "' owns no paths");
    }
    for (const path of paths) {
      if (!path.startsWith(installsInto + "/") || path.includes("..")) {
        throw new RuntimeModuleError("module_manifest", "optional layer '" + name + "' owns a path outside " + installsInto);
      }
    }
    layers[name] = { name, available: true, description: note || name + ": optional runtime module", file, sha256, bytes, installsInto, paths };
  }
  return { runtimeVersion: version, layers };
}

function ownedPaths(paths) {
  return paths.map((path) => path.replace(/^\/+/, ""));
}

/** Every extracted file must sit inside a path the release says the layer owns. */
function validateStaged(stage, layer) {
  const owned = ownedPaths(layer.paths);
  const walk = (directory, prefix) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const rel = prefix === "" ? entry.name : prefix + "/" + entry.name;
      if (entry.isDirectory()) walk(join(directory, entry.name), rel);
      else if (!owned.some((path) => rel === path || rel.startsWith(path + "/"))) {
        throw new RuntimeModuleError("module_archive", "optional layer '" + layer.name + "' carries " + rel);
      }
    }
  };
  walk(stage, "");
  for (const path of owned) {
    if (!existsSync(join(stage, path))) {
      throw new RuntimeModuleError("module_archive", "optional layer '" + layer.name + "' is missing " + path);
    }
  }
}

/** Move exactly the owned paths from staging under the root; restore what was replaced on any failure. */
function swapIn(root, stage, backup, layer) {
  const moved = [];
  const backupOf = (rel) => join(backup, rel);
  const targetOf = (rel) => {
    const target = resolve(root, rel);
    if (target !== root && !target.startsWith(root + sep)) {
      throw new RuntimeModuleError("module_manifest", "optional layer '" + layer.name + "' owns an unsafe path");
    }
    return target;
  };
  try {
    for (const rel of ownedPaths(layer.paths)) {
      const next = join(stage, rel);
      const target = targetOf(rel);
      const hadOld = existsSync(target) || isSymlink(target);
      if (hadOld) {
        const old = backupOf(rel);
        mkdirSync(dirname(old), { recursive: true, mode: 0o755 });
        renameSync(target, old);
      }
      mkdirSync(dirname(target), { recursive: true, mode: 0o755 });
      try {
        renameSync(next, target);
      } catch (error) {
        if (hadOld) renameSync(backupOf(rel), target);
        throw error;
      }
      moved.push({ rel, hadOld });
    }
  } catch (error) {
    for (const { rel, hadOld } of moved.reverse()) {
      const target = targetOf(rel);
      rmSync(target, { recursive: true, force: true });
      if (hadOld) renameSync(backupOf(rel), target);
    }
    throw error;
  }
}

function isSymlink(path) {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

/** tar needs xz for .tar.xz in this base rootfs; say so instead of failing with tar's own message. */
function assertExtractor(file) {
  const probe = spawnSync("tar", ["--version"], { stdio: "ignore" });
  if (probe.error || probe.status !== 0) {
    throw new RuntimeModuleError("module_no_extractor", "this runtime has no tar; the module cannot be unpacked");
  }
  if (!file.endsWith(".tar.xz")) return;
  const xz = spawnSync("xz", ["--version"], { stdio: "ignore" });
  if (xz.error || xz.status !== 0) {
    throw new RuntimeModuleError(
      "module_no_extractor",
      "this runtime base has no xz-utils, so .tar.xz layers cannot be unpacked; update the runtime first",
    );
  }
}

function run(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-2000);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolvePromise();
      else reject(new RuntimeModuleError("module_unpack", "unpacking failed: " + (stderr.trim() || "exit " + code)));
    });
  });
}

async function download(url, destination, expected) {
  let response;
  try {
    response = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS) });
  } catch (error) {
    throw new RuntimeModuleError("module_network", "could not reach the runtime release: " + (error?.message ?? "network error"));
  }
  if (!response.ok || response.body === null) {
    throw new RuntimeModuleError("module_network", "download failed: HTTP " + response.status);
  }
  const hash = createHash("sha256");
  let bytes = 0;
  const counting = async function* (source) {
    for await (const chunk of source) {
      hash.update(chunk);
      bytes += chunk.length;
      yield chunk;
    }
  };
  try {
    await pipeline(Readable.fromWeb(response.body), counting, createWriteStream(destination, { mode: 0o600, flags: "wx" }));
  } catch (error) {
    throw new RuntimeModuleError("module_network", "download was interrupted: " + (error?.message ?? "network error"));
  }
  if (bytes !== expected.bytes) {
    throw new RuntimeModuleError("module_size", "downloaded " + bytes + " bytes, the release says " + expected.bytes);
  }
  const actual = hash.digest("hex");
  if (actual !== expected.sha256) {
    throw new RuntimeModuleError("module_checksum", "sha256 " + actual + " does not match the release digest");
  }
}

/**
 * The optional-module manager: one manifest cache, one marker directory, one install path.
 * Tests point manifestUrl and root at a local server and a temp directory.
 */
export function createRuntimeModuleManager(options = {}) {
  const manifestUrl = options.manifestUrl ?? manifestUrlOf();
  const root = resolve(options.root ?? rootOf());
  const now = options.now ?? (() => Date.now());
  const markerDir = join(root, "runtime", "optional");
  let cache;          // { at, manifest }
  let snapshot;       // last list() result, for the synchronous prompt line
  let pending;

  const markerOf = (name) => join(markerDir, name + ".json");

  const readMarker = (name) => {
    try {
      const json = JSON.parse(readFileSync(markerOf(name), "utf8"));
      const paths = Array.isArray(json.paths) ? json.paths.filter((path) => typeof path === "string") : [];
      // A layer whose files are gone is not installed (an engine update replaces opt/dsh).
      if (paths.length === 0 || !paths.some((path) => existsSync(resolve(root, path.replace(/^\/+/, ""))))) return undefined;
      return { name, version: str(json.version) || str(json.runtimeVersion), installedAt: Number(json.installedAt) || 0, paths };
    } catch {
      return undefined;
    }
  };

  const loadManifest = async (refresh) => {
    if (!refresh && cache && now() - cache.at < MANIFEST_TTL_MS) return cache.manifest;
    if (!refresh && pending) return pending;
    pending = (async () => {
      let response;
      try {
        response = await fetch(manifestUrl, { redirect: "follow", signal: AbortSignal.timeout(30000) });
      } catch (error) {
        if (cache) return cache.manifest;   // a cached manifest still names the archives
        throw new RuntimeModuleError("module_network", "could not reach the runtime release: " + (error?.message ?? "network error"));
      }
      if (!response.ok) {
        if (cache) return cache.manifest;
        throw new RuntimeModuleError("module_network", "the runtime release returned HTTP " + response.status);
      }
      const manifest = parseManifest(await response.text());
      cache = { at: now(), manifest };
      return manifest;
    })();
    try {
      return await pending;
    } finally {
      pending = undefined;
    }
  };

  const describe = (manifest) => Object.values(manifest.layers).map((layer) => {
    const marker = layer.available ? readMarker(layer.name) : undefined;
    return {
      name: layer.name,
      bytes: layer.available ? layer.bytes : 0,
      installed: marker !== undefined,
      available: layer.available,
      description: layer.description,
    };
  }).sort((a, b) => a.name.localeCompare(b.name));

  const manager = {
    manifestUrl,
    root,
    markerDir,

    /** Optional layers with size, installed state and description; the manifest is cached. */
    async list({ refresh = false } = {}) {
      const manifest = await loadManifest(refresh);
      const modules = describe(manifest);
      snapshot = modules;
      return { runtimeVersion: manifest.runtimeVersion, modules };
    },

    /** Cached view, no network: what the prompt section may read while assembling. */
    promptLine() {
      if (snapshot === undefined || snapshot.length === 0) return "";
      const modules = snapshot.map((module) =>
        module.name + " (" + (module.installed ? "installed" : module.available ? "not installed, " + mib(module.bytes) : "not available") + ")",
      );
      return "Optional runtime modules: " + modules.join(", ") +
        ". If a document tool fails because the office module is missing, call runtime_install_module with name \"office\", then retry that tool.";
    },

    /** Warm the cache for the prompt line; a failure only leaves the line out. */
    async prepare() {
      try {
        await manager.list();
      } catch {
        snapshot = undefined;
      }
    },

    installed: readMarker,

    /**
     * Install one optional layer: download and verify into a temp directory, unpack into a
     * staging directory, then move exactly the owned paths into place and write the marker.
     */
    async install(name) {
      if (!MODULE_NAME.test(name)) {
        throw new RuntimeModuleError("module_unknown", "names an optional module such as office");
      }
      const manifest = await loadManifest(false);
      const layer = manifest.layers[name];
      if (layer === undefined) {
        const known = Object.keys(manifest.layers).join(", ") || "none";
        throw new RuntimeModuleError("module_unknown", "'" + name + "' is not an optional module; this release has " + known);
      }
      if (!layer.available) {
        throw new RuntimeModuleError("module_unavailable", "'" + name + "' is not available in " + (manifest.runtimeVersion || "this release") + ": " + layer.description);
      }
      const already = readMarker(name);
      if (already !== undefined) {
        return {
          name,
          version: already.version,
          installed: true,
          alreadyInstalled: true,
          paths: already.paths,
          restartRequired: false,
          note: "Already installed; nothing to do. Retry the tool that was missing it.",
        };
      }
      assertExtractor(layer.file);
      const temporary = join(root, "runtime", "tmp", name + "-" + process.pid + "-" + randomUUID());
      const downloadDir = join(temporary, "download");
      const stage = join(temporary, "stage");
      const backup = join(temporary, "backup");
      try {
        mkdirSync(downloadDir, { recursive: true, mode: 0o700 });
        mkdirSync(stage, { recursive: true, mode: 0o755 });
        mkdirSync(backup, { recursive: true, mode: 0o700 });
        const archive = join(downloadDir, layer.file);
        await download(layerUrl(manifestUrl, layer.file), archive, layer);
        await run("tar", [layer.file.endsWith(".tar.xz") ? "-xJf" : "-xzf", archive, "-C", stage]);
        validateStaged(stage, layer);
        swapIn(root, stage, backup, layer);
        const marker = {
          schema: 1,
          name,
          version: manifest.runtimeVersion,
          installedAt: now(),
          paths: layer.paths,
          source: "bridge",
        };
        mkdirSync(markerDir, { recursive: true, mode: 0o755 });
        const temporaryMarker = markerOf(name) + ".tmp";
        writeFileSync(temporaryMarker, JSON.stringify(marker, null, 2) + "\n", { mode: 0o644 });
        renameSync(temporaryMarker, markerOf(name));
        snapshot = describe(manifest);
        return {
          name,
          version: marker.version,
          installed: true,
          alreadyInstalled: false,
          paths: layer.paths,
          restartRequired: true,
          note: "Installed. Retry the tool that failed. If it still reports the module missing, restart the engine: " +
            "a running process may have cached the earlier failure. On the phone, stop and start the local engine.",
        };
      } finally {
        rmSync(temporary, { recursive: true, force: true });
      }
    },
  };
  return manager;
}

/**
 * The two tools this module contributes, as registry-ready definitions. The bridge is
 * loaded by absolute path where @deepseek-ai packages do not resolve, so these carry a
 * hand-written parameter and output schema instead of defineTool.
 */
export function createRuntimeModuleTools(manager) {
  const render = (_args, value) => [{ type: "text", text: JSON.stringify(value) }];
  return [
    {
      name: "runtime_modules",
      description:
        "List the optional runtime modules of this runtime (office today, python later): name, download size, " +
        "whether each is installed here, and what it is for. Call it when an office or document tool reports that " +
        "its module is missing, or before installing one. The release manifest is cached.",
      parameters: {
        type: "object",
        properties: {
          refresh: { type: "boolean", description: "Re-read the release manifest instead of using the cached copy." },
        },
        additionalProperties: false,
      },
      output: {
        schema: {
          type: "object",
          properties: {
            runtimeVersion: { type: "string" },
            modules: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  bytes: { type: "number" },
                  installed: { type: "boolean" },
                  available: { type: "boolean" },
                  description: { type: "string" },
                },
                required: ["name", "bytes", "installed", "available", "description"],
              },
            },
            note: { type: "string" },
          },
          required: ["runtimeVersion", "modules", "note"],
        },
        render,
      },
      async execute(args) {
        const listed = await manager.list({ refresh: args?.refresh === true });
        return { ...listed, note: "If a document tool fails because the office module is missing, call runtime_install_module with name \"office\", then retry that tool." };
      },
    },
    {
      name: "runtime_install_module",
      description:
        "Install one optional runtime module, e.g. name \"office\" to make the document tools work. Downloads the " +
        "release archive, verifies its sha256 and size, then unpacks exactly the paths the release says it owns. " +
        "Use it when a document tool fails because the office module is missing, then retry that tool. " +
        "Unknown or unavailable modules are refused, and a bad archive installs nothing.",
      parameters: {
        type: "object",
        properties: {
          name: { type: "string", description: "Module name from runtime_modules, for example office." },
        },
        required: ["name"],
        additionalProperties: false,
      },
      output: {
        schema: {
          type: "object",
          properties: {
            name: { type: "string" },
            version: { type: "string" },
            installed: { type: "boolean" },
            alreadyInstalled: { type: "boolean" },
            restartRequired: { type: "boolean" },
            note: { type: "string" },
            paths: { type: "array", items: { type: "string" } },
          },
          required: ["name", "version", "installed", "alreadyInstalled", "restartRequired", "note", "paths"],
        },
        render,
      },
      async execute(args) {
        const name = typeof args?.name === "string" ? args.name.trim() : "";
        if (name === "") throw new RuntimeModuleError("module_unknown", "name is required: for example office");
        return manager.install(name);
      },
    },
  ];
}
