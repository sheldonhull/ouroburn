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

    /// Self-signed app + user-deleted login item leaves `SMAppService` in `.requiresApproval`.
    /// `register()` succeeds but the item stays disabled until the user re-approves in System
    /// Settings. We surface that state so the UI can open the Login Items pane.
    static func apply(enabled: Bool, completion: @escaping (Result<Status, Error>) -> Void) {
        guard #available(macOS 13.0, *) else {
            completion(.failure(NSError(
                domain: "ouroburn.launchAtLogin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "macOS 13+ required"]
            )))
            return
        }
        do {
            let service = SMAppService.mainApp
            Log.info(Log.app, "Launch-at-login apply enabled=\(enabled) priorStatus=\(service.status.rawValue)")
            if enabled {
                // Don't trust cached .enabled — BTM can drop the record (user-deleted login item,
                // bundle path moved) while SMAppService still reports enabled. Force register so
                // the system writes a fresh BTM entry.
                try service.register()
                Log.info(Log.app, "Launch-at-login register postStatus=\(service.status.rawValue)")
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                    Log.info(Log.app, "Launch-at-login unregister postStatus=\(service.status.rawValue)")
                }
            }
            completion(.success(Status(service.status)))
        } catch {
            Log.error(Log.app, "Launch-at-login toggle failed: \(error)")
            completion(.failure(error))
        }
    }

    static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    enum Status: Sendable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unknown

        @available(macOS 13.0, *)
        init(_ raw: SMAppService.Status) {
            switch raw {
            case .enabled: self = .enabled
            case .notRegistered: self = .notRegistered
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            @unknown default: self = .unknown
            }
        }
    }
}
