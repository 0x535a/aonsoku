import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const output = resolve(process.argv[2] ?? "/tmp/aonsoku-carplay-qa");
mkdirSync(output, { recursive: true });
const build = join(output, "build");
const bundle = "github.realtvop.aonsoku.carplay-qa";
const devices = JSON.parse(
  execFileSync("xcrun", ["simctl", "list", "devices", "booted", "--json"], {
    encoding: "utf8",
  }),
);
const device = Object.values(devices.devices)
  .flat()
  .find((item) => item.state === "Booted" && item.name.startsWith("iPhone"));
if (!device)
  throw new Error(
    "Boot an iPhone Simulator first; this script never accesses a physical device",
  );
const log = join(output, "build.log");
try {
  const buildOutput = execFileSync(
    "xcodebuild",
    [
      "-project",
      join(root, "ios/App/App.xcodeproj"),
      "-scheme",
      "App",
      "-configuration",
      "Debug",
      "-sdk",
      "iphonesimulator",
      "-destination",
      `id=${device.udid}`,
      "-derivedDataPath",
      build,
      "-clonedSourcePackagesDirPath",
      process.env.AONSOKU_CARPLAY_PACKAGES ?? join(output, "packages"),
      `PRODUCT_BUNDLE_IDENTIFIER=${bundle}`,
      "CODE_SIGN_IDENTITY=-",
      "build",
    ],
    {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  writeFileSync(log, buildOutput);
} catch (error) {
  writeFileSync(log, `${error.stdout ?? ""}\n${error.stderr ?? ""}`);
  throw new Error(`Simulator build failed; see ${log}`, { cause: error });
}
const app = join(build, "Build/Products/Debug-iphonesimulator/App.app");
execFileSync("xcrun", ["simctl", "install", device.udid, app], {
  stdio: "inherit",
});
try {
  const container = execFileSync(
    "xcrun",
    ["simctl", "get_app_container", device.udid, bundle, "data"],
    { encoding: "utf8" },
  ).trim();
  const result = join(container, "Documents/carplay-qa-result.json");
  rmSync(result, { force: true });
  execFileSync(
    "xcrun",
    ["simctl", "launch", "--terminate-running-process", device.udid, bundle],
    {
      env: { ...process.env, SIMCTL_CHILD_AONSOKU_CARPLAY_QA: "1" },
      stdio: "inherit",
    },
  );
  const deadline = Date.now() + 45000;
  while (!existsSync(result) && Date.now() < deadline)
    await new Promise((done) => setTimeout(done, 250));
  if (!existsSync(result))
    throw new Error("CarPlay simulator fixture timed out");
  const data = JSON.parse(readFileSync(result, "utf8"));
  writeFileSync(join(output, "results.json"), JSON.stringify(data, null, 2));
  if (!data.passed) throw new Error(`CarPlay fixture failed: ${data.error}`);
  console.log(data);
} finally {
  spawnSync("xcrun", ["simctl", "terminate", device.udid, bundle], {
    stdio: "ignore",
  });
  spawnSync("xcrun", ["simctl", "uninstall", device.udid, bundle], {
    stdio: "ignore",
  });
}
