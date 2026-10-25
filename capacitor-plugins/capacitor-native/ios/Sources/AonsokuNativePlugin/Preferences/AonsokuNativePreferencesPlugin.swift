import Foundation
import Capacitor
import GRDB
import MediaPlayer

@objc(AonsokuNativePreferencesPlugin)
public class AonsokuNativePreferencesPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativePreferencesPlugin"
    public let jsName = "AonsokuNativePreferences"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "registerDynamicCoverDemand", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "releaseDynamicCoverDemand", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDynamicCoverCapabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "acquireDynamicCover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "releaseDynamicCover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLockScreenArtworkState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listLockScreenArtworkVideos", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteLockScreenArtworkVideo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearLockScreenArtworkVideos", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "configureLockScreenArtwork", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadLockScreenArtworkModel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelLockScreenArtworkDownload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteLockScreenArtworkModel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAllPreferences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreferences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreference", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deletePreference", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getQueueState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueueState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlayHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addToPlayHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearPlayHistory", returnType: CAPPluginReturnPromise),
    ]

    private var db: DatabasePool { DatabaseManager.shared.dbPool }
    private var prefs: PreferencesManager { PreferencesManager.shared }

    private let dynamicCoverOwner = UUID()
    private var leasedCoverRegistry: DynamicCoverRegistry<LockScreenArtworkAsset>?

    deinit {
        let registry = leasedCoverRegistry
        let owner = dynamicCoverOwner
        DispatchQueue.main.async { registry?.releaseAll(owner: owner); LockScreenArtworkDemand.shared.releaseAll(owner: owner) }
    }

    private func dynamicCoverFormats() -> [String] { ["square", "portrait"] }

    @objc func registerDynamicCoverDemand(_ call: CAPPluginCall) {
        guard let cover = call.getString("coverArtId"), !cover.isEmpty,
            let mode = call.getString("mode"), ["static", "dynamic"].contains(mode) else { call.reject("Invalid demand"); return }
        DispatchQueue.main.async {
            guard NativePlaybackService.dynamicCoverRegistryFromActive?.coverArtId == cover else { call.reject("Cover changed"); return }
            guard let id = LockScreenArtworkDemand.shared.add(owner: self.dynamicCoverOwner, cover: cover, motion: mode == "dynamic") else { call.reject("Demand limit reached"); return }
            call.resolve(["demandId": id])
        }
    }
    @objc func releaseDynamicCoverDemand(_ call: CAPPluginCall) {
        guard let id = call.getString("demandId") else { call.reject("Missing demand ID"); return }
        DispatchQueue.main.async {
            LockScreenArtworkDemand.shared.remove(id, owner: self.dynamicCoverOwner)
            call.resolve()
        }
    }

    @objc func getDynamicCoverCapabilities(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let formats = self.dynamicCoverFormats()
            call.resolve(["version": 1, "available": !formats.isEmpty, "formats": formats,
                          "reason": formats.isEmpty ? "unsupported-system" : NSNull()])
        }
    }

    @objc func acquireDynamicCover(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty,
            let format = call.getString("format"), ["square", "portrait", "any"].contains(format),
            let mode = call.getString("mode"), ["static", "dynamic"].contains(mode)
        else { call.reject("Invalid dynamic cover request"); return }
        DispatchQueue.main.async {
            guard format == "any" || self.dynamicCoverFormats().contains(format) else {
                call.resolve(["status": "unavailable", "reason": "unsupported-format"]); return
            }
            guard let registry = NativePlaybackService.dynamicCoverRegistryFromActive else {
                call.resolve(["status": "unavailable", "reason": "no-player"]); return
            }
            if self.leasedCoverRegistry !== registry {
                self.leasedCoverRegistry?.releaseAll(owner: self.dynamicCoverOwner)
                self.leasedCoverRegistry = registry
            }
            guard registry.coverArtId == coverArtId else {
                call.resolve(["status": "mismatch"]); return
            }
            let allowMotion = LockScreenArtworkMotionPolicy.shared.allowsPlayback
            let effectiveMode = mode == "dynamic" && allowMotion ? "dynamic" : "static"
            guard let asset = registry.current(coverArtId: coverArtId, format: format, mode: effectiveMode) else {
                call.resolve(["status": "pending", "motionAllowed": LockScreenArtworkMotionPolicy.shared.allowsPlayback]); return
            }
            let revision = registry.revision
            // Capture the asset during the asynchronous file lookup; never encode here.
            asset.requestVideo { url in
                DispatchQueue.main.async {
                    guard registry.revision == revision,
                        NativePlaybackService.dynamicCoverRegistryFromActive === registry
                    else { call.resolve(["status": "mismatch"]); return }
                    guard !asset.motion || LockScreenArtworkMotionPolicy.shared.allowsPlayback
                    else { call.resolve(["status": "pending", "motionAllowed": LockScreenArtworkMotionPolicy.shared.allowsPlayback]); return }
                    guard let url else { call.resolve(["status": "pending", "motionAllowed": LockScreenArtworkMotionPolicy.shared.allowsPlayback]); return }
                    guard let leaseId = registry.retain(asset, owner: self.dynamicCoverOwner) else {
                        call.resolve(["status": "busy", "reason": "lease-limit"]); return
                    }
                    call.resolve([
                        "status": "ready", "motionAllowed": LockScreenArtworkMotionPolicy.shared.allowsPlayback, "leaseId": leaseId, "assetId": asset.id,
                        "coverArtId": coverArtId, "format": asset.format.consumerFormat,
                        "stage": asset.motion ? (asset.backend == "camera" ? "camera" : "depth") : "static",
                        "backend": asset.motion ? asset.backend : "static",
                        "width": asset.format.width, "height": asset.format.height,
                        "duration": asset.motion ? asset.parameters.duration : 2,
                        "src": url.absoluteString,
                    ])
                }
            }
        }
    }

    @objc func releaseDynamicCover(_ call: CAPPluginCall) {
        guard let id = call.getString("leaseId") else { call.reject("Missing lease ID"); return }
        DispatchQueue.main.async {
            self.leasedCoverRegistry?.release(id, owner: self.dynamicCoverOwner)
            call.resolve()
        }
    }

    @objc func listLockScreenArtworkVideos(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            LockScreenArtworkStore.shared.listVideos { call.resolve(["videos": $0]) }
        }
    }

    @objc func deleteLockScreenArtworkVideo(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("Missing video ID"); return }
        DispatchQueue.main.async {
            LockScreenArtworkStore.shared.deleteVideo(id: id) { deleted in
                if deleted { call.resolve() }
                else { call.reject("Video is in use or could not be deleted") }
            }
        }
    }

    @objc func clearLockScreenArtworkVideos(_ call: CAPPluginCall) {
        let kind = call.getString("kind") ?? "all"
        guard ["all", "static", "dynamic"].contains(kind) else { call.reject("Unknown video kind"); return }
        DispatchQueue.main.async {
            LockScreenArtworkStore.shared.clearVideos(kind: kind) { deleted, retained in
                call.resolve(["deleted": deleted, "retained": retained])
            }
        }
    }

    @objc func getLockScreenArtworkState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            _ = LockScreenArtworkMotionPolicy.shared
            DispatchQueue.global(qos: .utility).async { call.resolve(LockScreenArtworkController.snapshot()) }
        }
    }

    @objc func configureLockScreenArtwork(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                let old = LockScreenArtworkSettings.shared.value
                var options: [String: Any] = [:]
                for key in ["immersiveEnabled", "dynamicEnabled", "quality", "wifiOnly", "motionAmplitude", "motionSpeed", "resourceProtectionEnabled"] {
                    if let value = call.getValue(key) { options[key] = value }
                }
                try LockScreenArtworkSettings.shared.configure(options)
                let updated = LockScreenArtworkSettings.shared.value
                if old.resourceProtectionEnabled != updated.resourceProtectionEnabled {
                    LockScreenArtworkModelManager.shared.resumeDeferred()
                }
                if old.immersiveEnabled && old.dynamicEnabled && !(updated.immersiveEnabled && updated.dynamicEnabled) && !LockScreenArtworkDemand.shared.dynamicRequested {
                    LockScreenArtworkModelManager.shared.stopAutomaticGeneration()
                }
                if old.wifiOnly != updated.wifiOnly {
                    LockScreenArtworkModelManager.shared.preferencesChanged()
                }
                call.resolve(LockScreenArtworkController.snapshot())
            } catch { call.reject("Invalid artwork settings", nil, error) }
        }
    }

    @objc func downloadLockScreenArtworkModel(_ call: CAPPluginCall) {
        guard let raw = call.getString("tier"), let tier = LockScreenArtworkTier(rawValue: raw) else {
            call.reject("Unknown DAV2 tier"); return
        }
        DispatchQueue.main.async {
            guard LockScreenArtworkController.supported else { call.reject("Immersive artwork requires iOS 26+"); return }
            LockScreenArtworkModelManager.shared.request(tier)
            call.resolve()
        }
    }

    @objc func cancelLockScreenArtworkDownload(_ call: CAPPluginCall) {
        guard let raw = call.getString("tier"), let tier = LockScreenArtworkTier(rawValue: raw) else {
            call.reject("Unknown DAV2 tier"); return
        }
        LockScreenArtworkModelManager.shared.cancel(tier)
        call.resolve()
    }

    @objc func deleteLockScreenArtworkModel(_ call: CAPPluginCall) {
        guard let raw = call.getString("tier"), let tier = LockScreenArtworkTier(rawValue: raw) else {
            call.reject("Unknown DAV2 tier"); return
        }
        LockScreenArtworkModelManager.shared.remove(tier)
        call.resolve()
    }

    // MARK: - Preferences

    @objc func getAllPreferences(_ call: CAPPluginCall) {
        let all = prefs.getAll()
        call.resolve(["preferences": all])
    }

    @objc func setPreferences(_ call: CAPPluginCall) {
        guard let preferences = call.getObject("preferences") else {
            call.reject("Missing preferences object")
            return
        }
        var pairs: [String: String] = [:]
        for (key, value) in preferences {
            if let str = value as? String {
                pairs[key] = str
            } else if let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]
            ) {
                pairs[key] = String(data: data, encoding: .utf8) ?? ""
            }
        }
        prefs.setValues(pairs)
        call.resolve()
    }

    @objc func setPreference(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("Missing key")
            return
        }
        let value = call.getValue("value")
        let stringValue: String
        if let str = value as? String {
            stringValue = str
        } else if let data = try? JSONSerialization.data(
            withJSONObject: value as Any, options: [.fragmentsAllowed]
        ) {
            stringValue = String(data: data, encoding: .utf8) ?? ""
        } else {
            stringValue = "\(value ?? "null")"
        }
        prefs.setValue(key, value: stringValue)
        call.resolve()
    }

    @objc func deletePreference(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("Missing key")
            return
        }
        prefs.deleteValue(key)
        call.resolve()
    }

    // MARK: - Queue State

    @objc func getQueueState(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stateJson = try self.db.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT stateJson FROM queueState WHERE key = 'current'"
                    )
                }
                call.resolve(["state": stateJson ?? NSNull()])
            } catch {
                call.reject("Failed to read queue state", nil, error)
            }
        }
    }

    @objc func setQueueState(_ call: CAPPluginCall) {
        guard let state = call.getString("state") else {
            call.reject("Missing state")
            return
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        DispatchQueue.global(qos: .utility).async {
            try? self.db.write { db in
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO queueState (key, stateJson, updatedAt)
                        VALUES ('current', ?, ?)
                        """,
                    arguments: [state, now]
                )
            }
            call.resolve()
        }
    }

    // MARK: - Play History

    @objc func getPlayHistory(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rows = try self.db.read { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT songJson FROM playHistory ORDER BY playedAt DESC LIMIT ?",
                        arguments: [limit]
                    )
                }
                let songs = rows.map { $0["songJson"] as String }
                call.resolve(["history": songs])
            } catch {
                call.reject("Failed to read play history", nil, error)
            }
        }
    }

    @objc func addToPlayHistory(_ call: CAPPluginCall) {
        guard let songJson = call.getString("song") else {
            call.reject("Missing song")
            return
        }
        let maxSize = call.getInt("maxSize") ?? 100
        let now = Int(Date().timeIntervalSince1970 * 1000)
        DispatchQueue.global(qos: .utility).async {
            try? self.db.write { db in
                try db.execute(
                    sql: "INSERT INTO playHistory (songJson, playedAt) VALUES (?, ?)",
                    arguments: [songJson, now]
                )
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playHistory") ?? 0
                if count > maxSize {
                    try db.execute(
                        sql: """
                            DELETE FROM playHistory WHERE id IN (
                                SELECT id FROM playHistory ORDER BY playedAt ASC LIMIT ?
                            )
                            """,
                        arguments: [count - maxSize]
                    )
                }
            }
            call.resolve()
        }
    }

    @objc func clearPlayHistory(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            try? self.db.write { db in
                try db.execute(sql: "DELETE FROM playHistory")
            }
            call.resolve()
        }
    }
}
