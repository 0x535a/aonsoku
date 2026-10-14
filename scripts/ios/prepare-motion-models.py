"""Prepare the three Apache-2.0 DAV2 Core ML models for Mac experiments.

Run in an isolated Python environment with coremltools>=9 and Xcode.
Paths, upstream revisions, precision and SHA256 are recorded. iOS production
downloads the same pinned packages itself; no weights are bundled in the app.
"""
import argparse
import concurrent.futures
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path

APPLE_REVISION = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
APPLE_REPO = "apple/coreml-depth-anything-v2-small"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        with urllib.request.urlopen(url, timeout=120) as response:
            destination.write_bytes(response.read())
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--apple-only", action="store_true")
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    tree = json.load(urllib.request.urlopen(
        f"https://huggingface.co/api/models/{APPLE_REPO}/tree/{APPLE_REVISION}?recursive=true"))
    names = ["DepthAnythingV2SmallF16", "DepthAnythingV2SmallF16P8", "DepthAnythingV2SmallF16P6"]
    items = [item for item in tree if item["type"] == "file" and
             any(item["path"].startswith(name + ".mlpackage/") for name in names)]
    def download(item):
        path = fetch(f"https://huggingface.co/{APPLE_REPO}/resolve/{APPLE_REVISION}/{item['path']}",
                     directory / item["path"])
        expected = item.get("lfs", {}).get("oid")
        if expected and digest(path) != expected:
            raise RuntimeError(f"SHA256 mismatch: {path}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        list(executor.map(download, items))
    print("Downloaded verified Apple candidates", flush=True)
    if args.apple_only:
        return
    import coremltools as ct
    manifest = []

    def compile_model(identifier, package, precision, license_name, source, inversion=False):
        compiled = directory / (package.stem + ".mlmodelc")
        if not compiled.exists():
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(directory)], check=True)
        hashes = {str(p.relative_to(package)): digest(p) for p in sorted(package.rglob("*")) if p.is_file()}
        spec = ct.models.MLModel(str(package), skip_model_load=True).get_spec()
        input_feature = spec.description.input[0]
        output_feature = spec.description.output[0]
        entry = {"id": identifier, "path": compiled.name, "precision": precision,
                 "license": license_name, "source": source, "sha256": hashes,
                 "input": input_feature.name, "output": output_feature.name,
                 "width": input_feature.type.imageType.width,
                 "height": input_feature.type.imageType.height, "metricDepth": inversion,
                 "packageBytes": sum(p.stat().st_size for p in package.rglob("*") if p.is_file()),
                 "compiledBytes": sum(p.stat().st_size for p in compiled.rglob("*") if p.is_file())}
        manifest.append(entry)
        print(f"Ready {identifier}: {entry['packageBytes']} bytes, input {entry['width']}x{entry['height']}", flush=True)

    for name, identifier, precision in zip(names, ["dav2-f16", "dav2-p8", "dav2-p6"],
                                          ["W16A16", "palette-W8A16", "palette-W6A16"]):
        compile_model(identifier, directory / (name + ".mlpackage"), precision, "Apache-2.0",
                      f"https://huggingface.co/{APPLE_REPO}/tree/{APPLE_REVISION}")
    (directory / "manifest.json").write_text(json.dumps(
        {"coremltools": ct.__version__, "models": manifest}, indent=2) + "\n")
    print(f"Manifest: {directory / 'manifest.json'}", flush=True)


if __name__ == "__main__":
    main()
