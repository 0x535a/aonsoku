# macOS dynamic artwork

This directory owns the macOS implementation. It is compiled only for Darwin by
`src-tauri/build.rs`; neither the build nor these sources import code from the
iOS plugin. The renderer, DAV2 adapter, video cache and model catalog started as
an independent copy of the iOS implementation at `36cb9f2b`, then received macOS
storage, AppKit lifecycle and VM-pressure adaptations. Keep behavior aligned by
reviewing the contract in `doc/dynamic-cover/fullscreen.md`, not by including
another platform's files.

- `DynamicCoverService.swift`: native original-cover download, serialized
  publication, progressive static/camera/depth preparation, per-session leases,
  settings/model/cache/diagnostic commands and the small C ABI.
- `ArtworkDepthModel.swift`, `ArtworkModelManager.swift`,
  `ArtworkModelCatalog.swift`: one serial Core ML boundary, pinned Apple DAV2
  Small FP16/P8/P6 packages, streamed verified downloads and local compilation.
- `ArtworkMotion.swift`: macOS resource policy, OCR protection and Metal depth
  displacement. Loss of keyboard focus does not pause desktop generation;
  hiding the application does. Memory warnings pause for 60 seconds and cap
  recovery to P6 for 180 seconds. Serious thermal state, Low Power Mode and
  Reduce Motion stop motion generation/publication.
- `ArtworkSettings.swift`: app-scoped atomic settings, tier and trajectory rules.
- `ArtworkRenderer.swift`, `ArtworkVideo.swift`, `ArtworkStore.swift`: bounded
  decode/frame buffers, complete silent loops and a live-asset-protected LRU.
- `DynamicCoverRegistry.swift`: publication and strong references for leases.
- `ArtworkDiagnostics.swift`, `ArtworkMeasurement.swift`: phase timing,
  process footprint, renderer/depth/pipeline snapshots with no authenticated URL.

Rust (`src/dynamic_cover.rs`) supplies the app's data directory, session identity
and bundled license at startup. `playback` accepts only the native media-session
source; the renderer command allowlist excludes source/path/session operations.
The renderer gets opaque `aonsoku-artwork://` lease URLs. The registered protocol
supports WebKit range/HEAD requests and resolves a path only through an active
native lease. Reloading/destroying a WebView invalidates its session and releases
all its files. No second audio player or audio session is created.

Data lives under the Tauri app-data `dynamic-cover` directory: `preferences`,
`OriginalCovers`, `AonsokuArtworkModels`, and `AonsokuArtwork`. Originals are
validated complete images fetched without Subsonic's `size` argument (12 files /
64 MiB); video LRU limits remain 12 files / 24 MiB, with live assets protected.
Model weights are never bundled. `DepthAnythingV2-LICENSE.txt` is bundled and
copied alongside downloaded models with their notice.

Verification from the repository root:

```sh
cargo test --manifest-path src-tauri/Cargo.toml --lib dynamic_cover::tests::webkit_video_ranges
node scripts/macos/test-dynamic-cover.mjs
AONSOKU_TEST_MODEL_DOWNLOAD=1 node scripts/macos/test-dynamic-cover.mjs
```

The default smoke checks static/camera stages without fetching model weights;
the explicit network variant checks pinned P6 download/compile/inference and
actual depth video. Both exercise the production C ABI, source validation,
publication and lease protection. Output is under
`doc/dynamic-cover/exp/macos-service`. `AONSOKU_MACOS_ARTWORK_LIBRARY` can point to
the library just produced by Cargo to avoid recompiling production Swift;
`AONSOKU_MACOS_SMOKE_MODEL_CACHE` can reuse a previous verified smoke model folder.
Neither option is consumed by the application.
