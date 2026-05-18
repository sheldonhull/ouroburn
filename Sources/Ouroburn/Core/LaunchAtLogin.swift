import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` so the settings UI doesn't have to deal with the
/// async/throws API or status enum directly. macOS 13+ only.
enum LaunchAtLogin {
    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func apply(enabled: Bool, completion: @escaping (Error?) -> Void) {
        guard #available(macOS 13.0, *) else {
            completion(NSError(
                domain: "ouroburn.launchAtLogin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "macOS 13+ required"]
            ))
            return
        }
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    Log.info(Log.app, "Launch-at-login registered (status=\(service.status.rawValue))")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    Log.info(Log.app, "Launch-at-login unregistered (status=\(service.status.rawValue))")
                }
            }
            completion(nil)
        } catch {
            Log.error(Log.app, "Launch-at-login toggle failed: \(error)")
            completion(error)
        }
    }
}
