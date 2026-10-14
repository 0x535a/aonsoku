import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const models = resolve(process.argv[2] ?? "/tmp/aonsoku-depth-models");
const cover = resolve(
  process.argv[3] ?? join(root, "doc/ios-lock-screen/cover.png"),
);
const output = resolve(
  process.argv[4] ?? join(root, "doc/ios-lock-screen/exp/mac-20261014"),
);
const build = mkdtempSync(join(tmpdir(), "aonsoku-motion-experiment-"));
const native = join(
  root,
  "capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin/Audio",
);
const architecture = process.arch === "x64" ? "x86_64" : process.arch;
mkdirSync(output, { recursive: true });
function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(result.stderr || result.stdout || `${command} failed`);
  return result;
}
try {
  run("xcrun", [
    "swiftc",
    "-O",
    "-D",
    "DEBUG",
    "-target",
    `${architecture}-apple-macosx13.0`,
    ...[
      "Renderer",
      "Video",
      "Motion",
      "Measurement",
      "DepthModel",
      "Settings",
      "ModelCatalog",
    ].map((name) => join(native, `LockScreenArtwork${name}.swift`)),
    join(root, "scripts/ios/motion-cover-experiment.swift"),
    "-o",
    join(build, "experiment"),
  ]);
  const result = run(join(build, "experiment"), [cover, output], {
    env: {
      ...process.env,
      AONSOKU_MOTION_MODELS_DIR: models,
      AONSOKU_MOTION_OUTPUT_DIR: output,
    },
    maxBuffer: 20 * 1024 * 1024,
  });
  writeFileSync(join(output, "performance.log"), result.stdout + result.stderr);
  console.log(result.stdout);
} finally {
  rmSync(build, { recursive: true, force: true });
}
