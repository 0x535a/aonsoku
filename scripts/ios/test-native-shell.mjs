import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, cpSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const output = resolve(process.argv[2] ?? "/tmp/aonsoku-native-shell-qa");
const devices = JSON.parse(execFileSync("xcrun", ["simctl", "list", "devices", "available", "-j"], { encoding: "utf8" }));
const requestedDevice = process.env.AONSOKU_QA_SIMULATOR_UDID;
const device = Object.values(devices.devices).flat().find((device) => requestedDevice ? device.udid === requestedDevice && device.state === "Booted" : device.state === "Booted");
if (!device) throw new Error("Boot an iOS Simulator before running native shell QA");
const staging = mkdtempSync(join(tmpdir(), "aonsoku-shell-qa-"));
const app = join(staging, "ShellQA.app");
const bundle = "com.aonsoku.native-shell-qa";
mkdirSync(app);
const sdk = execFileSync("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], { encoding: "utf8" }).trim();
const arch = process.arch === "arm64" ? "arm64" : "x86_64";
try {
  execFileSync("xcrun", ["--sdk", "iphonesimulator", "swiftc", "-sdk", sdk, "-target", `${arch}-apple-ios15.0-simulator`, "-o", join(app, "ShellQA"), join(root, "scripts/ios/native-shell-qa.swift"), join(root, "ios/App/App/NativeBottomShellView.swift")], { stdio: "inherit" });
  writeFileSync(join(app, "Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string><key>CFBundleExecutable</key><string>ShellQA</string><key>CFBundleName</key><string>ShellQA</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>15.0</string><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/><key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict/></dict></dict></plist>`);
  execFileSync("codesign", ["--force", "--sign", "-", app], { stdio: "inherit" });
  execFileSync("xcrun", ["simctl", "install", device.udid, app]);
  const container = execFileSync("xcrun", ["simctl", "get_app_container", device.udid, bundle, "data"], { encoding: "utf8" }).trim();
  const resultPath = join(container, "Documents/results.json");
  const launched = spawnSync("xcrun", ["simctl", "launch", "--terminate-running-process", device.udid, bundle], { encoding: "utf8", timeout: 20_000 });
  if (launched.error || launched.status !== 0) throw new Error(`Fixture launch failed: ${launched.error?.message ?? launched.stderr}`);
  const deadline = Date.now() + 20_000;
  while (!existsSync(resultPath) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 250));
  if (!existsSync(resultPath)) throw new Error(`Fixture did not finish on ${device.name}; inspect Simulator crash reports`);
  const result = JSON.parse(readFileSync(resultPath, "utf8"));
  if (!Object.values(result).every((value) => value === "passed")) throw new Error(`Fixture failed: ${JSON.stringify(result)}`);
  mkdirSync(output, { recursive: true });
  cpSync(join(container, "Documents"), output, { recursive: true });
  console.log(`Native shell layout/control QA passed. PNGs and results: ${output}`);
} finally {
  spawnSync("xcrun", ["simctl", "terminate", device.udid, bundle]);
  spawnSync("xcrun", ["simctl", "uninstall", device.udid, bundle]);
  rmSync(staging, { recursive: true, force: true });
}
