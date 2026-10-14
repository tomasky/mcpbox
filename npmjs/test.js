"use strict";

// Unit tests for the launcher's platform mapping and URL construction. Run
// with `node --test` from this directory.

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const lib = require("./lib.js");

test("maps every supported Node platform-arch to a release target", () => {
  assert.equal(lib.TARGETS["linux-x64"], "linux-x86_64");
  assert.equal(lib.TARGETS["linux-arm64"], "linux-aarch64");
  assert.equal(lib.TARGETS["darwin-arm64"], "darwin-aarch64");
  assert.equal(Object.keys(lib.TARGETS).length, 3);
});

test("resolves the repository slug from package.json", () => {
  assert.equal(lib.repoSlug(), "tomasky/mcpbox");
});

test("falls back from the pinned version to latest", () => {
  const urls = lib.downloadUrls("linux-x86_64");
  assert.equal(urls.length, 2);
  assert.match(
    urls[0],
    /^https:\/\/github\.com\/tomasky\/mcpbox\/releases\/download\/v\d+\.\d+\.\d+\/mcpbox-linux-x86_64$/
  );
  assert.equal(
    urls[1],
    "https://github.com/tomasky/mcpbox/releases/latest/download/mcpbox-linux-x86_64"
  );
});

test("MCPBOX_DOWNLOAD_BASE replaces both default URLs", () => {
  const saved = process.env.MCPBOX_DOWNLOAD_BASE;
  process.env.MCPBOX_DOWNLOAD_BASE = "https://mirror.example.com/mcpbox/";
  try {
    assert.deepEqual(lib.downloadUrls("darwin-aarch64"), [
      "https://mirror.example.com/mcpbox/mcpbox-darwin-aarch64",
    ]);
  } finally {
    if (saved === undefined) delete process.env.MCPBOX_DOWNLOAD_BASE;
    else process.env.MCPBOX_DOWNLOAD_BASE = saved;
  }
});

test("MCPBOX_VERSION wins over the package version and tolerates a v prefix", () => {
  const saved = process.env.MCPBOX_VERSION;
  process.env.MCPBOX_VERSION = "v9.9.9";
  try {
    assert.equal(lib.version(), "9.9.9");
    assert.match(lib.downloadUrls("linux-aarch64")[0], /\/v9\.9\.9\//);
  } finally {
    if (saved === undefined) delete process.env.MCPBOX_VERSION;
    else process.env.MCPBOX_VERSION = saved;
  }
});

test("the cache directory can be redirected", () => {
  const saved = process.env.MCPBOX_CACHE_DIR;
  process.env.MCPBOX_CACHE_DIR = "/tmp/mcpbox-test-cache";
  try {
    assert.equal(lib.cacheDir(), "/tmp/mcpbox-test-cache");
    assert.equal(
      lib.binaryPath("linux-x86_64"),
      path.join("/tmp/mcpbox-test-cache", `mcpbox-${lib.version()}-linux-x86_64`)
    );
  } finally {
    if (saved === undefined) delete process.env.MCPBOX_CACHE_DIR;
    else process.env.MCPBOX_CACHE_DIR = saved;
  }
});

test("MCPBOX_BINARY short-circuits every download path", async () => {
  const saved = process.env.MCPBOX_BINARY;
  process.env.MCPBOX_BINARY = "/bin/sh";
  try {
    assert.equal(await lib.ensureBinary(), "/bin/sh");
  } finally {
    if (saved === undefined) delete process.env.MCPBOX_BINARY;
    else process.env.MCPBOX_BINARY = saved;
  }
});

test("MCPBOX_BINARY pointing nowhere is a clear error", async () => {
  const saved = process.env.MCPBOX_BINARY;
  process.env.MCPBOX_BINARY = "/nonexistent/mcpbox";
  try {
    await assert.rejects(lib.ensureBinary(), /does not exist/);
  } finally {
    if (saved === undefined) delete process.env.MCPBOX_BINARY;
    else process.env.MCPBOX_BINARY = saved;
  }
});

test("an unsupported platform explains itself", async () => {
  const saved = process.env.MCPBOX_BINARY;
  delete process.env.MCPBOX_BINARY;
  const realPlatform = process.platform;
  const realArch = process.arch;
  try {
    Object.defineProperty(process, "platform", { value: "sunos" });
    Object.defineProperty(process, "arch", { value: "sparc" });
    await assert.rejects(lib.ensureBinary(), /does not ship a binary/);
  } finally {
    Object.defineProperty(process, "platform", { value: realPlatform });
    Object.defineProperty(process, "arch", { value: realArch });
    if (saved === undefined) delete process.env.MCPBOX_BINARY;
    else process.env.MCPBOX_BINARY = saved;
  }
});
