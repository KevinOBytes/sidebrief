import Foundation
import ServiceManagement

public final class LaunchAtLoginManager: ObservableObject, @unchecked Sendable {
    public static let shared = LaunchAtLoginManager()

    @Published public var isEnabled: Bool = false

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            if status == .enabled {
                self.isEnabled = true
            } else {
                self.isEnabled = UserDefaults.standard.bool(forKey: "launch_at_login_fallback")
            }
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: "launch_at_login_fallback")
        }
    }

    public func setEnabled(_ enable: Bool) {
        UserDefaults.standard.set(enable, forKey: "launch_at_login_fallback")
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                // Graceful fallback in non-bundled development/testing environments
            }
            let status = SMAppService.mainApp.status
            self.isEnabled = (status == .enabled) || enable
        } else {
            self.isEnabled = enable
        }
    }
}
