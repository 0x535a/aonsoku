import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const derived = join(homedir(), "Library/Developer/Xcode/DerivedData");
const candidates = [
  ...(process.env.AONSOKU_GRDB_PATH ? [process.env.AONSOKU_GRDB_PATH] : []),
  "/tmp/aonsoku-carplay-qa/packages/checkouts/GRDB.swift",
  "/tmp/aonsoku-carplay-build/SourcePackages/checkouts/GRDB.swift",
  ...readdirSync(derived).map((name) =>
    join(derived, name, "SourcePackages/checkouts/GRDB.swift"),
  ),
];
const grdb = candidates.find((path) => existsSync(join(path, "Package.swift")));
if (!grdb) throw new Error("Resolve the iOS project's GRDB package first");
const build = mkdtempSync(join(tmpdir(), "aonsoku-carplay-library-"));
const source = join(build, "Sources/CarPlayQA");
mkdirSync(source, { recursive: true });
const plugin = join(
  root,
  "capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin",
);
const files = [
  "CarPlay/CarPlayModels.swift",
  "CarPlay/CarPlayLibraryProvider.swift",
  "Audio/NativePlaybackRequest.swift",
  "Audio/NativeQueueSongFactory.swift",
  "Audio/NativeQueueEngine.swift",
  "Audio/NativeShuffleEngine.swift",
  "Audio/PlaybackPersistState.swift",
  "Audio/NativeSourceResolver.swift",
  "Audio/AudioCacheUtils.swift",
  "Bridge/SubsonicHTTPClient.swift",
  "Bridge/SubsonicAuthBuilder.swift",
  "Data/Database/Migrations.swift",
  "Data/Database/SearchHelper.swift",
  "Preferences/PreferencesManager.swift",
  "Debug/NativeLogger.swift",
  "Image/ImageCacheManager.swift",
  "Image/ImageCacheUtils.swift",
  "Image/CoverImageQuality.swift",
  ...readdirSync(join(plugin, "Data/Models")).map(
    (name) => `Data/Models/${name}`,
  ),
  ...["Album", "Artist", "Song", "Playlist", "CacheMeta"].map(
    (name) => `Data/Repositories/${name}Repository.swift`,
  ),
];
for (const file of files)
  cpSync(join(plugin, file), join(source, file.split("/").at(-1)));
cpSync(
  join(root, "scripts/ios/carplay-library-tests.swift"),
  join(source, "CarPlayLibraryTests.swift"),
);
writeFileSync(
  join(build, "Package.swift"),
  `// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "CarPlayQA", platforms: [.macOS(.v13)], dependencies: [.package(path: ${JSON.stringify(grdb)})], targets: [.executableTarget(name: "CarPlayQA", dependencies: [.product(name: "GRDB", package: "GRDB.swift")])])\n`,
);
try {
  execFileSync("swift", ["run", "--package-path", build, "CarPlayQA"], {
    stdio: "inherit",
  });
} finally {
  rmSync(build, { recursive: true, force: true });
}
