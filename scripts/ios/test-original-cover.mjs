import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const derived = join(homedir(), "Library/Developer/Xcode/DerivedData");
const grdb = readdirSync(derived).map((name) => join(derived, name, "SourcePackages/checkouts/GRDB.swift")).find((path) => existsSync(join(path, "Package.swift")));
if (!grdb) throw new Error("Resolve the iOS Xcode project's GRDB package before running this offline test");
const build = mkdtempSync(join(tmpdir(), "aonsoku-original-cover-tests-"));
const output = resolve(process.argv[2] ?? "/tmp/aonsoku-original-cover-qa");
const source = join(build, "Sources/CoverQA");
mkdirSync(source, { recursive: true });
const plugin = join(root, "capacitor-plugins/capacitor-native/ios/Sources/AonsokuNativePlugin");
for (const file of ["Image/ImageCacheManager.swift", "Image/ImageCacheUtils.swift", "Image/CoverImageQuality.swift", "Data/Models/CacheMetaRecord.swift", "Data/Repositories/CacheMetaRepository.swift", "Bridge/SubsonicAuthBuilder.swift"]) cpSync(join(plugin, file), join(source, file.split("/").at(-1)));
cpSync(join(root, "scripts/ios/original-cover-tests.swift"), join(source, "OriginalCoverTests.swift"));
writeFileSync(join(build, "Package.swift"), `// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "CoverQA", platforms: [.macOS(.v13)], dependencies: [.package(path: ${JSON.stringify(grdb)})], targets: [.executableTarget(name: "CoverQA", dependencies: [.product(name: "GRDB", package: "GRDB.swift")])])\n`);
try {
  execFileSync("swift", ["run", "--package-path", build, "CoverQA", output], { stdio: "inherit" });
} finally { rmSync(build, { recursive: true, force: true }); }
