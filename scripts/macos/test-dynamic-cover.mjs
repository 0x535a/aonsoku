import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  cpSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin")
  throw new Error("This smoke requires macOS and Xcode.");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const native = join(root, "src-tauri/native/artwork");
const build = mkdtempSync(join(tmpdir(), "aonsoku-macos-artwork-"));
const output = resolve(
  process.argv[2] ?? join(root, "doc/dynamic-cover/exp/macos-service"),
);
mkdirSync(output, { recursive: true });
const cover = readFileSync(join(root, "doc/dynamic-cover/cover.png"));
let requests = 0;
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname !== "/rest/getCoverArt" || url.searchParams.has("size")) {
    response.writeHead(400).end();
    return;
  }
  requests++;
  response
    .writeHead(200, {
      "Content-Type": "image/png",
      "Content-Length": cover.length,
    })
    .end(cover);
});
try {
  const library = process.env.AONSOKU_MACOS_ARTWORK_LIBRARY;
  const nativeArgs = library
    ? [library]
    : readdirSync(native)
        .filter((name) => name.endsWith(".swift"))
        .map((name) => join(native, name));
  const result = spawnSync(
    "xcrun",
    [
      "swiftc",
      "-parse-as-library",
      "-O",
      "-target",
      `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx13.0`,
      "-import-objc-header",
      join(root, "scripts/macos/artwork-bridge.h"),
      ...nativeArgs,
      join(root, "scripts/macos/dynamic-cover-smoke.swift"),
      "-o",
      join(build, "smoke"),
    ],
    { cwd: root, encoding: "utf8" },
  );
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  for (const name of [
    "static.mp4",
    "camera.mp4",
    "depth.mp4",
    "depth.png",
    "result.json",
    "status.json",
    "service.log",
  ]) {
    rmSync(join(output, name), { force: true });
  }
  if (process.env.AONSOKU_MACOS_SMOKE_MODEL_CACHE) {
    mkdirSync(join(build, "runtime"), { recursive: true });
    cpSync(
      process.env.AONSOKU_MACOS_SMOKE_MODEL_CACHE,
      join(build, "runtime/AonsokuArtworkModels"),
      { recursive: true },
    );
  }
  const child = spawn(
    join(build, "smoke"),
    [
      join(build, "runtime"),
      join(native, "DepthAnythingV2-LICENSE.txt"),
      `http://127.0.0.1:${port}/rest/getCoverArt?id=fixture&size=300`,
      output,
      process.env.AONSOKU_MACOS_SMOKE_LEGACY_ONLY === "1"
        ? "legacy"
        : process.env.AONSOKU_TEST_MODEL_DOWNLOAD === "1"
          ? "1"
          : "0",
      join(
        root,
        "doc/dynamic-cover/exp/dav2-product-mac/dav2-p6/motion-960.mp4",
      ),
      createHash("sha256").update(cover).digest("hex"),
    ],
    { cwd: root },
  );
  let log = "";
  child.stdout.on("data", (chunk) => {
    log += chunk;
    appendFileSync(join(output, "service.log"), chunk);
  });
  child.stderr.on("data", (chunk) => {
    log += chunk;
    appendFileSync(join(output, "service.log"), chunk);
  });
  const status = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });
  writeFileSync(join(output, "service.log"), log);
  if (status !== 0)
    throw new Error(
      `macOS artwork smoke failed (${status}); see ${join(output, "service.log")}`,
    );
  if (requests !== 1)
    throw new Error(`Expected one original download, received ${requests}`);
  console.log(
    log
      .split("\n")
      .filter(
        (line) =>
          line.includes("smoke passed") || line.includes("legacy reuse passed"),
      )
      .join("\n"),
  );
  console.log(`Artifacts: ${output}`);
} finally {
  server.close();
  rmSync(build, { recursive: true, force: true });
}
