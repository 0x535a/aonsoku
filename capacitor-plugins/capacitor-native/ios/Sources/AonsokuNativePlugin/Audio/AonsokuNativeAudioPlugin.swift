import Capacitor
import Foundation

/// The bridge is an adapter; the process-wide service owns playback even without a WebView.
@objc(AonsokuNativeAudioPlugin)
public class AonsokuNativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativeAudioPlugin"
    public let jsName = "AonsokuNativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRepeatMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setShuffle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "markAsShuffled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipToNext", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipToPrevious", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateMetadata", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateRemotePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRemotePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "preload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clear", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "storeAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAudioFileSize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAudioFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addToUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeFromUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reorderContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playAtIndex", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFullState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveSongs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelDownload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getScrobbleBuffer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearScrobbleBuffer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSystemVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSystemVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolumeHUDEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLikeActive", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSleepTimer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelSleepTimer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSleepTimerRemaining", returnType: CAPPluginReturnPromise),
    ]

    private var eventToken: UUID?
    private var service: NativePlaybackService { .shared }

    public override func load() {
        super.load()
        service.start()
        service.volumeContainerView = bridge?.viewController?.view
        eventToken = service.observeEvents { [weak self] name, data in
            self?.notifyListeners(name, data: data)
        }
    }

    deinit {
        if let token = eventToken {
            DispatchQueue.main.async { NativePlaybackService.shared.removeEventObserver(token) }
        }
    }

    private func request(_ call: CAPPluginCall) -> NativePlaybackRequest {
        NativePlaybackRequest(
            options: call.options as? [String: Any] ?? [:], success: { data in call.resolve(data) },
            failure: { message, code, error in call.reject(message, code, error) })
    }

    @objc func load(_ call: CAPPluginCall) { service.load(request(call)) }
    @objc func play(_ call: CAPPluginCall) { service.play(request(call)) }
    @objc func pause(_ call: CAPPluginCall) { service.pause(request(call)) }
    @objc func stop(_ call: CAPPluginCall) { service.stop(request(call)) }
    @objc func seek(_ call: CAPPluginCall) { service.seek(request(call)) }
    @objc func setRepeatMode(_ call: CAPPluginCall) { service.setRepeatMode(request(call)) }
    @objc func setShuffle(_ call: CAPPluginCall) { service.setShuffle(request(call)) }
    @objc func markAsShuffled(_ call: CAPPluginCall) { service.markAsShuffled(request(call)) }
    @objc func setQueue(_ call: CAPPluginCall) { service.setQueue(request(call)) }
    @objc func skipToNext(_ call: CAPPluginCall) { service.skipToNext(request(call)) }
    @objc func skipToPrevious(_ call: CAPPluginCall) { service.skipToPrevious(request(call)) }
    @objc func updateMetadata(_ call: CAPPluginCall) { service.updateMetadata(request(call)) }
    @objc func updateRemotePlaybackState(_ call: CAPPluginCall) { service.updateRemotePlaybackState(request(call)) }
    @objc func clearRemotePlaybackState(_ call: CAPPluginCall) { service.clearRemotePlaybackState(request(call)) }
    @objc func preload(_ call: CAPPluginCall) { service.preload(request(call)) }
    @objc func clear(_ call: CAPPluginCall) { service.clear(request(call)) }
    @objc func storeAudioFile(_ call: CAPPluginCall) { service.storeAudioFile(request(call)) }
    @objc func resolveAudioFile(_ call: CAPPluginCall) { service.resolveAudioFile(request(call)) }
    @objc func getAudioFileSize(_ call: CAPPluginCall) { service.getAudioFileSize(request(call)) }
    @objc func deleteAudioFile(_ call: CAPPluginCall) { service.deleteAudioFile(request(call)) }
    @objc func clearAudioFiles(_ call: CAPPluginCall) { service.clearAudioFiles(request(call)) }
    @objc func setContextQueue(_ call: CAPPluginCall) { service.setContextQueue(request(call)) }
    @objc func addToUserQueue(_ call: CAPPluginCall) { service.addToUserQueue(request(call)) }
    @objc func removeFromUserQueue(_ call: CAPPluginCall) { service.removeFromUserQueue(request(call)) }
    @objc func clearUserQueue(_ call: CAPPluginCall) { service.clearUserQueue(request(call)) }
    @objc func updateContextQueue(_ call: CAPPluginCall) { service.updateContextQueue(request(call)) }
    @objc func reorderContextQueue(_ call: CAPPluginCall) { service.reorderContextQueue(request(call)) }
    @objc func playAtIndex(_ call: CAPPluginCall) { service.playAtIndex(request(call)) }
    @objc func getFullState(_ call: CAPPluginCall) { service.getFullState(request(call)) }
    @objc func resolveSongs(_ call: CAPPluginCall) { service.resolveSongs(request(call)) }
    @objc func downloadAudioFile(_ call: CAPPluginCall) { service.downloadAudioFile(request(call)) }
    @objc func cancelDownload(_ call: CAPPluginCall) { service.cancelDownload(request(call)) }
    @objc func getScrobbleBuffer(_ call: CAPPluginCall) { service.getScrobbleBuffer(request(call)) }
    @objc func clearScrobbleBuffer(_ call: CAPPluginCall) { service.clearScrobbleBuffer(request(call)) }
    @objc func setSystemVolume(_ call: CAPPluginCall) { service.setSystemVolume(request(call)) }
    @objc func getSystemVolume(_ call: CAPPluginCall) { service.getSystemVolume(request(call)) }
    @objc func setVolumeHUDEnabled(_ call: CAPPluginCall) { service.setVolumeHUDEnabled(request(call)) }
    @objc func setLikeActive(_ call: CAPPluginCall) { service.setLikeActive(request(call)) }
    @objc func setSleepTimer(_ call: CAPPluginCall) { service.setSleepTimer(request(call)) }
    @objc func cancelSleepTimer(_ call: CAPPluginCall) { service.cancelSleepTimer(request(call)) }
    @objc func getSleepTimerRemaining(_ call: CAPPluginCall) { service.getSleepTimerRemaining(request(call)) }
    func debugSnapshot() -> AudioDebugSnapshot { service.debugSnapshot() }
    func debugPlayPause() { service.debugPlayPause() }
    func debugSkipNext() { service.debugSkipNext() }
    func debugSkipPrevious() { service.debugSkipPrevious() }
}
