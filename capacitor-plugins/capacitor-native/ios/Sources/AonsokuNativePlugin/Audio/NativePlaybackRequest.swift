import Foundation

/// Transport-neutral adapter for the existing audio operations. Only the plugin
/// translates CAPPluginCall; native clients never construct a Capacitor object.
final class NativePlaybackRequest {
    private let options: [String: Any]
    private let success: ([String: Any]) -> Void
    private let failure: (String, String?, Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(
        options: [String: Any] = [:],
        success: @escaping ([String: Any]) -> Void = { _ in },
        failure: @escaping (String, String?, Error?) -> Void = { _, _, _ in }
    ) {
        self.options = options
        self.success = success
        self.failure = failure
    }

    func getString(_ key: String) -> String? { options[key] as? String }
    func getBool(_ key: String) -> Bool? { options[key] as? Bool }
    func getInt(_ key: String) -> Int? { (options[key] as? NSNumber)?.intValue }
    func getDouble(_ key: String) -> Double? { (options[key] as? NSNumber)?.doubleValue }
    func getFloat(_ key: String) -> Float? { (options[key] as? NSNumber)?.floatValue }
    func getObject(_ key: String) -> [String: Any]? { options[key] as? [String: Any] }
    func getArray(_ key: String) -> [Any]? { options[key] as? [Any] }
    func getValue(_ key: String) -> Any? { options[key] }

    private func finish(_ action: () -> Void) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { action() }
    }

    func resolve(_ data: [String: Any] = [:]) { finish { success(data) } }
    func reject(_ message: String, _ code: String? = nil, _ error: Error? = nil) {
        finish { failure(message, code, error) }
    }
}
