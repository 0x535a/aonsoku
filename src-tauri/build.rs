use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        build_artwork();
    }
    tauri_build::build()
}

fn build_artwork() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let native = root.join("native/artwork");
    let output = PathBuf::from(env::var("OUT_DIR").unwrap());
    let architecture = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => panic!("Unsupported macOS artwork architecture: {other}"),
    };
    let mut sources: Vec<PathBuf> = [
        "Renderer",
        "Video",
        "Store",
        "Motion",
        "DepthModel",
        "Settings",
        "ModelCatalog",
        "ModelManager",
        "Measurement",
        "Diagnostics",
    ]
    .iter()
    .map(|name| native.join(format!("Artwork{name}.swift")))
    .collect();
    sources.push(native.join("DynamicCoverRegistry.swift"));
    sources.push(native.join("ArtworkSourceQuality.swift"));
    sources.push(root.join("native/artwork/DynamicCoverService.swift"));
    for source in &sources {
        println!("cargo:rerun-if-changed={}", source.display());
    }
    let library = output.join("libAonsokuArtwork.a");
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-O",
            "-emit-library",
            "-static",
            "-parse-as-library",
            "-module-name",
            "AonsokuArtwork",
            "-D",
            "AONSOKU_MACOS_HOST",
            "-target",
            &format!("{architecture}-apple-macosx13.0"),
        ])
        .args(&sources)
        .arg("-o")
        .arg(&library)
        .status()
        .expect("Xcode Swift compiler is required");
    assert!(status.success(), "macOS Core ML artwork compilation failed");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=AonsokuArtwork");
    // Mach-O Swift objects carry LC_LINKER_OPTION autolinks; unlike ELF builds,
    // Apple toolchains do not ship swift-autolink-extract. Make SDK runtimes
    // discoverable to the final Rust/clang link.
    let sdk = Command::new("xcrun")
        .arg("--show-sdk-path")
        .output()
        .unwrap();
    let sdk = PathBuf::from(String::from_utf8(sdk.stdout).unwrap().trim());
    println!(
        "cargo:rustc-link-search=native={}",
        sdk.join("usr/lib/swift").display()
    );
    for framework in [
        "Foundation",
        "AppKit",
        "CoreML",
        "CoreImage",
        "Vision",
        "AVFoundation",
        "CoreGraphics",
        "CoreVideo",
        "ImageIO",
        "Network",
        "UniformTypeIdentifiers",
        "Metal",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    let swiftc = Command::new("xcrun")
        .args(["--find", "swiftc"])
        .output()
        .unwrap();
    let compiler = PathBuf::from(String::from_utf8(swiftc.stdout).unwrap().trim());
    let runtime = compiler.parent().unwrap().join("../lib/swift/macosx");
    println!("cargo:rustc-link-search=native={}", runtime.display());
    println!("cargo:rustc-link-search=native=/usr/lib/swift");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
}
