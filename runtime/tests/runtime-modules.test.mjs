// Optional runtime modules (office today, python later): the manifest contract, digest and
// availability refusals, and installs that leave nothing behind when they fail.
//   node --test runtime/tests/runtime-modules.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  RuntimeModuleError, createRuntimeModuleManager, createRuntimeModuleTools, parseManifest,
} from "../bridge/dsh-go-bridge/lib/runtime-modules.js";

const OWNED = "/opt/dsh/node_modules/@deepseek-ai/kit";
const PAYLOAD = {
  "opt/dsh/node_modules/@deepseek-ai/kit/package.json": "{\"name\":\"kit\"}",
  "opt/dsh/node_modules/@deepseek-ai/kit/index.js": "export default 1;",
};

function tempRoot(t) {
  const root = mkdtempSync(join(tmpdir(), "dsh-modules-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

/** One archive holding the given guest-relative files, xz when the host can write it. */
function archive(t, files) {
  const work = mkdtempSync(join(tmpdir(), "dsh-archive-"));
  t.after(() => rmSync(work, { recursive: true, force: true }));
  const tree = join(work, "tree");
  for (const [rel, body] of Object.entries(files)) {
    const path = join(tree, rel);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, body);
  }
  for (const [suffix, flag] of [["xz", "-cJf"], ["gz", "-czf"]]) {
    const file = join(work, "office-" + suffix + ".tar." + suffix);
    try {
      execFileSync("tar", [flag, file, "-C", tree, "."], { stdio: "ignore" });
      const bytes = readFileSync(file);
      return {
        name: "office-" + suffix + ".tar." + suffix,
        body: bytes,
        bytes: bytes.length,
        sha256: createHash("sha256").update(bytes).digest("hex"),
      };
    } catch {
      // No xz writer on this host: try gzip, the other form the manifest allows.
    }
  }
  throw new Error("this host has no tar that can write a test archive");
}

async function serve(t, files) {
  const requests = [];
  const server = createServer((req, res) => {
    requests.push(req.url);
    const body = files[req.url];
    if (body === undefined) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { "content-type": "application/octet-stream" }).end(body);
  });
  await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
  t.after(() => new Promise((closed) => server.close(closed)));
  return { base: "http://127.0.0.1:" + server.address().port, requests };
}

function manifest({ entry, paths = [OWNED], digest, size, extraLayers = {} }) {
  return {
    schema: 2,
    runtimeVersion: "r15-dsh0.2.2-test",
    abi: "arm64-v8a",
    layers: {
      base: { role: "required", file: "base.tar.xz", sha256: "0".repeat(64), bytes: 1 },
      engine: { role: "required", file: "engine.tar.xz", sha256: "0".repeat(64), bytes: 1 },
      office: {
        role: "optional", available: true, file: entry.name, description: "document conversion",
        sha256: digest ?? entry.sha256, bytes: size ?? entry.bytes,
        installsInto: "/opt/dsh", requires: ["base", "engine"], paths,
      },
      ...extraLayers,
    },
  };
}

test("manifest parsing reads optional layers and refuses guesses", (t) => {
  const entry = archive(t, { "opt/dsh/node_modules/@deepseek-ai/kit/package.json": "x" });
  const parsed = parseManifest(JSON.stringify(manifest({ entry })));
  assert.deepEqual(Object.keys(parsed.layers), ["office"]);
  assert.equal(parsed.layers.office.paths[0], OWNED);
  assert.equal(parsed.layers.office.description, "document conversion");

  const unavailable = parseManifest(JSON.stringify({
    runtimeVersion: "r1", layers: { python: { role: "optional", available: false, note: "not shipped yet" } },
  }));
  assert.equal(unavailable.layers.python.available, false);
  assert.match(unavailable.layers.python.description, /not shipped yet/);

  const broken = (mutate) => {
    const json = manifest({ entry });
    mutate(json.layers.office);
    return JSON.stringify(json);
  };
  const code = (text) => assert.throws(() => parseManifest(text), (error) => {
    assert.ok(error instanceof RuntimeModuleError, String(error));
    return error.code === "module_manifest";
  });
  code(broken((layer) => { layer.paths = ["/etc/passwd"]; }));
  code(broken((layer) => { layer.sha256 = "not-a-digest"; }));
  code(broken((layer) => { layer.file = "office.zip"; }));
  code(broken((layer) => { layer.installsInto = "relative"; }));
  code("not json");
});

test("a digest mismatch installs nothing and keeps no temp state", async (t) => {
  const root = tempRoot(t);
  const entry = archive(t, PAYLOAD);
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({ entry, digest: "f".repeat(64) })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  await assert.rejects(manager.install("office"), (error) => {
    assert.equal(error.code, "module_checksum");
    return true;
  });
  assert.equal(existsSync(join(root, "opt")), false);
  assert.equal(existsSync(join(root, "runtime", "optional")), false);
  assert.deepEqual(readdirSync(join(root, "runtime", "tmp")), []);
});

test("unknown and unavailable modules are refused without a download", async (t) => {
  const root = tempRoot(t);
  const entry = archive(t, PAYLOAD);
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({
      entry,
      extraLayers: { python: { role: "optional", available: false, note: "not shipped yet" } },
    })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  await assert.rejects(manager.install("sqlite"), (error) => error.code === "module_unknown");
  await assert.rejects(manager.install("python"), (error) => error.code === "module_unavailable");
  assert.deepEqual(server.requests, ["/manifest.json"]);
  assert.equal(existsSync(join(root, "opt")), false);
});

test("an archive carrying files outside its owned paths is refused before the swap", async (t) => {
  const root = tempRoot(t);
  const entry = archive(t, { ...PAYLOAD, "opt/dsh/node_modules/other/index.js": "stray" });
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({ entry })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  await assert.rejects(manager.install("office"), (error) => error.code === "module_archive");
  assert.equal(existsSync(join(root, "opt")), false);
  assert.deepEqual(readdirSync(join(root, "runtime", "tmp")), []);
});

test("a failed swap restores the paths it already replaced", async (t) => {
  const root = tempRoot(t);
  mkdirSync(join(root, "opt", "dsh"), { recursive: true });
  writeFileSync(join(root, "opt", "dsh", "x"), "old x");
  // /opt/dsh/a is a file, so creating /opt/dsh/a/b after the first path moved must fail.
  writeFileSync(join(root, "opt", "dsh", "a"), "not a directory");
  const entry = archive(t, {
    "opt/dsh/x": "new x",
    "opt/dsh/a/b/file.txt": "new b",
  });
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({ entry, paths: ["/opt/dsh/x", "/opt/dsh/a/b"] })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  await assert.rejects(manager.install("office"));
  assert.equal(readFileSync(join(root, "opt", "dsh", "x"), "utf8"), "old x");
  assert.equal(existsSync(join(root, "runtime", "optional", "office.json")), false);
  assert.deepEqual(readdirSync(join(root, "runtime", "tmp")), []);
});

test("install writes the marker the app reads and reports already installed next time", async (t) => {
  const root = tempRoot(t);
  const entry = archive(t, PAYLOAD);
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({ entry })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  const first = await manager.install("office");
  assert.equal(first.installed, true);
  assert.equal(first.alreadyInstalled, false);
  assert.equal(first.restartRequired, true);
  assert.match(first.note, /restart the engine/);
  assert.equal(
    readFileSync(join(root, "opt/dsh/node_modules/@deepseek-ai/kit/index.js"), "utf8"),
    PAYLOAD["opt/dsh/node_modules/@deepseek-ai/kit/index.js"],
  );

  const marker = JSON.parse(readFileSync(join(root, "runtime/optional/office.json"), "utf8"));
  assert.equal(marker.version, "r15-dsh0.2.2-test");
  assert.ok(Number.isSafeInteger(marker.installedAt));
  assert.deepEqual(marker.paths, [OWNED]);
  assert.equal(marker.source, "bridge");

  const before = server.requests.length;
  const again = await manager.install("office");
  assert.equal(again.alreadyInstalled, true);
  assert.equal(server.requests.length, before, "an installed module is not downloaded again");

  const listed = await manager.list();
  assert.deepEqual(listed.modules.map((module) => [module.name, module.installed, module.available]), [["office", true, true]]);
  assert.match(manager.promptLine(), /office \(installed\)/);
  assert.match(manager.promptLine(), /runtime_install_module/);

  // A marker from a build that wrote "runtimeVersion" still reads as installed.
  writeFileSync(
    join(root, "runtime/optional/python.json"),
    JSON.stringify({ schema: 1, name: "python", runtimeVersion: "r15-old", installedAt: 1, paths: [OWNED] }),
  );
  assert.equal(manager.installed("python").version, "r15-old");
});

test("the tools carry their guidance and refuse a missing name", async (t) => {
  const root = tempRoot(t);
  const entry = archive(t, PAYLOAD);
  const server = await serve(t, {
    "/manifest.json": JSON.stringify(manifest({ entry })),
    ["/" + entry.name]: entry.body,
  });
  const manager = createRuntimeModuleManager({ root, manifestUrl: server.base + "/manifest.json" });
  const [list, install] = createRuntimeModuleTools(manager);
  assert.equal(list.name, "runtime_modules");
  assert.equal(install.name, "runtime_install_module");
  assert.match(install.description, /office/);
  assert.match(install.description, /retry/);
  assert.equal(manager.promptLine(), "", "nothing is claimed before the manifest is read");

  const listed = await list.execute({});
  assert.equal(listed.modules[0].name, "office");
  assert.equal(listed.modules[0].installed, false);
  assert.match(listed.note, /runtime_install_module/);
  assert.match(manager.promptLine(), /office \(not installed/);

  const installed = await install.execute({ name: "office" });
  assert.equal(installed.installed, true);
  assert.equal(install.output.schema.properties.installed.type, "boolean");

  await assert.rejects(install.execute({}), (error) => error.code === "module_unknown");
  await assert.rejects(install.execute({ name: "missing" }), (error) => error.code === "module_unknown");
});
