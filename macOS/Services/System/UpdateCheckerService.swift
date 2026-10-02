import Foundation
import AppKit

@MainActor
public final class UpdateCheckerService: ObservableObject {
    public static let shared = UpdateCheckerService()

    @Published public var isChecking: Bool = false
    @Published public var updateAvailable: Bool = false
    @Published public var latestVersion: String = ""
    @Published public var currentVersion: String = "1.0.0"
    @Published public var releaseNotes: String = ""
    @Published public var downloadUrl: String = ""
    @Published public var lastCheckedDate: Date? = nil
    @Published public var statusMessage: String? = nil
    @Published public var isPresentingUpdateSheet: Bool = false

    private init() {
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentVersion = bundleVersion
        }
        self.lastCheckedDate = UserDefaults.standard.object(forKey: "last_update_check_date") as? Date
    }

    /// Performs an update check against the backend endpoint.
    public func checkForUpdates(userInitiated: Bool = false) async {
        guard !isChecking else { return }
        self.isChecking = true
        self.statusMessage = "Checking for updates..."

        let serverUrl = resolveApiBaseUrl()
        guard let url = URL(string: "\(serverUrl)/api/v1/updates/check?version=\(currentVersion)") else {
            self.isChecking = false
            self.statusMessage = "Invalid update server URL."
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8.0
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }

            let hasUpdate = json["hasUpdate"] as? Bool ?? false
            let remoteVersion = json["latestVersion"] as? String ?? ""
            let notes = json["releaseNotes"] as? String ?? ""
            let dlUrl = json["downloadUrl"] as? String ?? ""

            self.latestVersion = remoteVersion
            self.releaseNotes = notes
            self.downloadUrl = dlUrl
            self.updateAvailable = hasUpdate
            self.lastCheckedDate = Date()
            UserDefaults.standard.set(Date(), forKey: "last_update_check_date")

            if hasUpdate {
                self.statusMessage = "Update available: v\(remoteVersion)"
                if userInitiated {
                    self.isPresentingUpdateSheet = true
                }
            } else {
                self.statusMessage = "You're up to date (v\(currentVersion))."
            }
        } catch {
            if userInitiated {
                self.statusMessage = "Could not check for updates. Please try again later."
            }
        }

        self.isChecking = false
    }

    /// Triggers download of the latest release DMG.
    public func downloadUpdate() {
        guard let url = URL(string: downloadUrl) else {
            if let fallback = URL(string: "\(resolveApiBaseUrl())/downloads/Sidebrief.dmg") {
                NSWorkspace.shared.open(fallback)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    nonisolated public static func isVersion(_ remote: String, greaterThan local: String) -> Bool {
        let cleanRemote = remote.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let cleanLocal = local.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)

        let rParts = cleanRemote.split(separator: ".").compactMap { Int($0) }
        let lParts = cleanLocal.split(separator: ".").compactMap { Int($0) }

        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    private func resolveApiBaseUrl() -> String {
        if let custom = UserDefaults.standard.string(forKey: "backend_api_url"), !custom.isEmpty {
            return custom
        }
        if let env = ProcessInfo.processInfo.environment["SIDEBRIEF_API_URL"], !env.isEmpty {
            return env
        }
        return "http://localhost:3100"
    }
}
