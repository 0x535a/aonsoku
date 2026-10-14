import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, cpSync } from "node:fs";
import { resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const output = resolve(process.argv[2] ?? "/tmp/aonsoku-native-shell-bridge-qa");
const devices = JSON.parse(execFileSync("xcrun", ["simctl", "list", "devices", "available", "-j"], { encoding: "utf8" }));
const device = Object.values(devices.devices).flat().find((item) => item.state === "Booted");
if (!device) throw new Error("Boot an iOS Simulator before running Capacitor bridge QA");
const bundle = "github.realtvop.aonsoku";
const settings = JSON.parse(execFileSync("xcodebuild", ["-project", "ios/App/App.xcodeproj", "-scheme", "App", "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", `platform=iOS Simulator,id=${device.udid}`, "-showBuildSettings", "-json"], { cwd: root, encoding: "utf8" }))[0].buildSettings;
const app = join(settings.TARGET_BUILD_DIR, settings.FULL_PRODUCT_NAME);
execFileSync("xcrun", ["simctl", "install", device.udid, app]);
mkdirSync(output, { recursive: true });
const child = spawn("xcrun", ["simctl", "launch", "--terminate-running-process", "--console", device.udid, bundle], {
  env: { ...process.env, SIMCTL_CHILD_AONSOKU_SHELL_BRIDGE_QA: "1" },
  stdio: ["ignore", "pipe", "pipe"],
});
let log = "";
try {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Bridge QA timed out\n${log.slice(-5000)}`)), 35_000);
    const receive = (chunk) => {
      log += chunk.toString();
      if (log.includes("NATIVE_SHELL_BRIDGE_QA_PASSED")) { clearTimeout(timeout); resolve(); }
      if (log.includes("NATIVE_SHELL_BRIDGE_QA_FAILED")) { clearTimeout(timeout); reject(new Error(log.slice(-5000))); }
    };
    child.stdout.on("data", receive);
    child.stderr.on("data", receive);
    child.on("error", (error) => { clearTimeout(timeout); reject(error); });
    child.on("exit", (code) => { clearTimeout(timeout); reject(new Error(`App exited (${code})\n${log.slice(-5000)}`)); });
  });
  const container = execFileSync("xcrun", ["simctl", "get_app_container", device.udid, bundle, "data"], { encoding: "utf8" }).trim();
  cpSync(join(container, "Documents/native-shell-bridge-qa.json"), join(output, "results.json"));
  execFileSync("xcrun", ["simctl", "io", device.udid, "screenshot", join(output, "capacitor-shell.png")]);
  console.log(`Real Capacitor shell state/layout round trip passed: ${output}`);
} finally {
  execFileSync("xcrun", ["simctl", "terminate", device.udid, bundle]);
  child.kill();
}
