import AVFoundation
import AppKit
import CryptoKit
import Foundation

@main
struct DynamicCoverSmoke {
  static let owner = UUID().uuidString
  static func command(_ operation: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
    var payload = payload
    payload["owner"] = owner
    let data = try JSONSerialization.data(withJSONObject: [
      "operation": operation, "payload": payload,
    ])
    let pointer = String(decoding: data, as: UTF8.self).withCString { aonsoku_artwork_call($0) }!
    defer { aonsoku_artwork_free(pointer) }
    let result =
      try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
    if let error = result["error"] as? String { throw NSError(domain: error, code: 1) }
    return result
  }

  static func main() {
    let args = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    args[1].withCString { root in args[2].withCString { aonsoku_artwork_initialize(root, $0) } }
    DispatchQueue.global(qos: .utility).async {
      do {
        try run(args)
        DispatchQueue.main.async { exit(0) }
      } catch {
        fputs("Artwork smoke failed: \(error)\n", stderr)
        DispatchQueue.main.async { exit(1) }
      }
    }
    app.run()
  }

  static func legacy(_ args: [String]) throws {
    let output = URL(fileURLWithPath: args[4], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let cache = URL(fileURLWithPath: args[1]).appendingPathComponent("AonsokuArtwork")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let id = "motion-v6-dav2-p6-a100-s100-720x960-" + args[7]
    let seeded = cache.appendingPathComponent(id + ".mp4")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: args[6]), to: seeded)
    _ = try command("openSession")
    _ = try command(
      "configure",
      [
        "immersiveEnabled": false, "dynamicEnabled": false,
        "quality": "p6", "motionAmplitude": 1, "motionSpeed": 1,
      ])
    _ = try command("playback", ["artworkUrl": args[3]])
    _ = try command("registerDemand", ["coverArtId": "fixture", "mode": "dynamic"])
    var found: [String: Any]?
    for _ in 0..<100 {
      let result = try command(
        "acquire", ["coverArtId": "fixture", "format": "any", "mode": "dynamic"])
      if let lease = result["leaseId"] as? String {
        if result["assetId"] as? String == id {
          found = result
          break
        }
        _ = try command("release", ["leaseId": lease])
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard let found, let lease = found["leaseId"] as? String else {
      throw NSError(domain: "Legacy video was not reused", code: 1)
    }
    precondition(found["width"] as? Int == 720 && found["height"] as? Int == 960)
    let path = try command("leaseFile", ["leaseId": lease])["path"] as! String
    let sameBytes =
      try Data(contentsOf: URL(fileURLWithPath: path))
      == Data(contentsOf: URL(fileURLWithPath: args[6]))
    precondition(sameBytes)
    let diagnostics = try command("diagnostics")
    let phases = diagnostics["phases"] as? [String: Any] ?? [:]
    precondition(!phases.keys.contains(where: { $0.hasPrefix("model-") }))
    let report: [String: Any] = [
      "asset": found, "byteIdentical": sameBytes, "diagnostics": diagnostics,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("legacy-reuse.json"))
    _ = try command("releaseAll")
    _ = try command("playback")
    print(
      "macOS legacy reuse passed: unchanged 720x960 file, any-format lease, no Core ML inference")
  }

  static func run(_ args: [String]) throws {
    if args[5] == "legacy" {
      try legacy(args)
      return
    }
    let output = URL(fileURLWithPath: args[4], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = try command("openSession")
    _ = try command(
      "configure",
      [
        "immersiveEnabled": false, "dynamicEnabled": false,
        "wifiOnly": false, "quality": "p6", "motionAmplitude": 1.5, "motionSpeed": 2,
      ])
    let network = args[5] == "1"
    if network {
      _ = try command("download", ["tier": "p6"])
    }
    // With downloads disabled, explicitly cancel automatic requests before
    // setting the source; the smoke still checks static/camera generation.
    else {
      _ = try command("cancel", ["tier": "p6"])
    }
    _ = try command("playback", ["artworkUrl": args[3]])
    let before = try command(
      "acquire", ["coverArtId": "fixture", "format": "any", "mode": "dynamic"])
    precondition(before["status"] as? String == "pending")
    let demand = try command("registerDemand", ["coverArtId": "fixture", "mode": "dynamic"])
    precondition(demand["demandId"] != nil)
    let started = Date()
    var observed: [String: [String: Any]] = [:]
    var staticLease: String?
    var depthLease: String?
    var lastStatus = Date.distantPast
    let limit: Double = network ? 240 : 30
    while Date().timeIntervalSince(started) < limit {
      let result = try command(
        "acquire", ["coverArtId": "fixture", "format": "square", "mode": "dynamic"])
      if let lease = result["leaseId"] as? String, let stage = result["stage"] as? String {
        if observed[stage] == nil {
          var snapshot = result
          snapshot["elapsedMs"] = Int(Date().timeIntervalSince(started) * 1000)
          observed[stage] = snapshot
          let path = try command("leaseFile", ["leaseId": lease])["path"] as! String
          try FileManager.default.copyItem(
            at: URL(fileURLWithPath: path), to: output.appendingPathComponent("\(stage).mp4"))
        }
        if stage == "depth" {
          depthLease = lease
        } else {
          _ = try command("release", ["leaseId": lease])
        }
      }
      if staticLease == nil {
        let video = try command(
          "acquire", ["coverArtId": "fixture", "format": "square", "mode": "static"])
        staticLease = video["leaseId"] as? String
      }
      if Date().timeIntervalSince(lastStatus) > 2 {
        var status = try command("diagnostics")
        status.removeValue(forKey: "depthPreview")
        try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("status.json"), options: .atomic)
        lastStatus = Date()
      }
      if depthLease != nil || (!network && observed["camera"] != nil) { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    var diagnostics = try command("diagnostics")
    if let preview = diagnostics.removeValue(forKey: "depthPreview") as? String,
      let data = Data(base64Encoded: String(preview.split(separator: ",", maxSplits: 1)[1]))
    {
      try data.write(to: output.appendingPathComponent("depth.png"))
    }
    let report: [String: Any] = [
      "observed": observed, "diagnostics": diagnostics,
      "downloadTest": network, "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("result.json"))
    guard let staticLease, observed["camera"] != nil else {
      throw NSError(domain: "Missing static/camera stage", code: 1)
    }
    if network && depthLease == nil {
      throw NSError(domain: "DAV2 depth was not published", code: 1)
    }
    let protected = try command("clearVideos", ["kind": "all"])
    precondition((protected["retained"] as? Int ?? 0) >= 1)
    let staticPath = try command("leaseFile", ["leaseId": staticLease])["path"] as! String
    precondition(FileManager.default.fileExists(atPath: staticPath))
    let mismatch = try command(
      "acquire", ["coverArtId": "other", "format": "square", "mode": "dynamic"])
    precondition(mismatch["status"] as? String == "mismatch")
    _ = try command("releaseAll")
    let releasedFile = try command("leaseFile", ["leaseId": staticLease])
    precondition(releasedFile["path"] == nil)
    _ = try command("playback")
    _ = try command("configure", ["immersiveEnabled": false])
    let disabled = try command(
      "acquire", ["coverArtId": "fixture", "format": "square", "mode": "static"])
    precondition(disabled["status"] as? String == "mismatch")
    print(
      "macOS service smoke passed: \(observed.keys.sorted()), lease protection, mismatch and session cleanup"
    )
  }
}
