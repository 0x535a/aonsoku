import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const plugin = join(
  root,
  "capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin",
);
const build = mkdtempSync(join(tmpdir(), "aonsoku-playback-sync-"));
try {
  const executable = join(build, "PlaybackSyncTests");
  const sources = [
    "Audio/NativeQueueEngine.swift",
    "Audio/NativeShuffleEngine.swift",
    "Audio/PlaybackPersistState.swift",
    "Audio/NativeSourceResolver.swift",
    "Audio/AudioCacheUtils.swift",
    "Bridge/KeychainManager.swift",
    "Bridge/SubsonicAuthBuilder.swift",
    "Debug/NativeLogger.swift",
  ].map((file) => join(plugin, file));
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-parse-as-library",
      ...sources,
      join(root, "scripts/ios/playback-sync-tests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, { stdio: "inherit" });
} finally {
  rmSync(build, { recursive: true, force: true });
}
