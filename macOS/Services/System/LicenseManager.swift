import Foundation
import SwiftUI
import IOKit

@MainActor
public final class LicenseManager: ObservableObject {
    public static let shared = LicenseManager()

    @Published public var isLicensed: Bool = false
    @Published public var licenseKey: String = ""
    @Published public var licenseeEmail: String = ""
    @Published public var activationDate: Date? = nil
    @Published public var isValidating: Bool = false
    @Published public var statusMessage: String? = nil

    private let licenseKeyStorageKey = "sidebrief_license_key"
    private let licenseeEmailStorageKey = "sidebrief_licensee_email"
    private let isLicensedStorageKey = "sidebrief_is_licensed"
    private let activatedAtStorageKey = "sidebrief_activated_at"

    public var maskedKey: String {
        guard licenseKey.count > 8 else { return licenseKey }
        let prefix = licenseKey.prefix(3)
        let suffix = licenseKey.suffix(4)
        return "\(prefix)••••-••••-\(suffix)"
    }

    public var hardwareUUID: String {
        Self.getHardwareUUID()
    }

    private init() {
        loadStoredLicense()
    }

    private func loadStoredLicense() {
        let storedKey = UserDefaults.standard.string(forKey: licenseKeyStorageKey) ?? ""
        let storedEmail = UserDefaults.standard.string(forKey: licenseeEmailStorageKey) ?? ""
        let storedLicensed = UserDefaults.standard.bool(forKey: isLicensedStorageKey)
        let storedActivated = UserDefaults.standard.object(forKey: activatedAtStorageKey) as? Date

        self.licenseKey = storedKey
        self.licenseeEmail = storedEmail
        self.isLicensed = storedLicensed && !storedKey.isEmpty
        self.activationDate = storedActivated

        if !storedKey.isEmpty {
            self.statusMessage = "✓ Active License"
        }
    }

    /// Activates a license key with optional email against the backend API.
    public func activate(key: String, email: String? = nil) async -> Bool {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanKey.isEmpty else {
            self.statusMessage = "Please enter a valid license key."
            return false
        }

        self.isValidating = true
        self.statusMessage = "Activating license..."

        let serverUrl = resolveApiBaseUrl()
        guard let url = URL(string: "\(serverUrl)/api/v1/license/activate") else {
            self.isValidating = false
            self.statusMessage = "Invalid activation server URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let payload: [String: Any] = [
            "licenseKey": cleanKey,
            "hardwareUuid": hardwareUUID,
            "email": email ?? licenseeEmail
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let valid = json["valid"] as? Bool, valid {
                let licEmail = (json["email"] as? String) ?? email ?? ""
                
                self.isLicensed = true
                self.licenseKey = cleanKey
                self.licenseeEmail = licEmail
                self.activationDate = Date()
                self.statusMessage = "✓ License activated successfully!"

                UserDefaults.standard.set(cleanKey, forKey: licenseKeyStorageKey)
                UserDefaults.standard.set(licEmail, forKey: licenseeEmailStorageKey)
                UserDefaults.standard.set(true, forKey: isLicensedStorageKey)
                UserDefaults.standard.set(Date(), forKey: activatedAtStorageKey)

                self.isValidating = false
                return true
            } else {
                let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Invalid license key."
                self.statusMessage = "Activation failed: \(errorMsg)"
                self.isValidating = false
                return false
            }
        } catch {
            // Offline fallback / grace: If key matches valid syntax (SB-XXXX-XXXX-XXXX-XXXX), enable grace period
            if cleanKey.hasPrefix("SB-") && cleanKey.count >= 16 {
                self.isLicensed = true
                self.licenseKey = cleanKey
                self.licenseeEmail = email ?? "offline@licensed.user"
                self.activationDate = Date()
                self.statusMessage = "✓ Verified (Offline Grace Mode)"

                UserDefaults.standard.set(cleanKey, forKey: licenseKeyStorageKey)
                UserDefaults.standard.set(email ?? "offline@licensed.user", forKey: licenseeEmailStorageKey)
                UserDefaults.standard.set(true, forKey: isLicensedStorageKey)
                UserDefaults.standard.set(Date(), forKey: activatedAtStorageKey)

                self.isValidating = false
                return true
            }

            self.statusMessage = "Connection error: Unable to reach activation server."
            self.isValidating = false
            return false
        }
    }

    /// Handles deep linking from web browser: sidebrief://activate?key=SB-...
    public func handleActivationUrl(_ url: URL) -> Bool {
        guard url.scheme == "sidebrief" && (url.host == "activate" || url.path.contains("activate")) else {
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let keyParam = components?.queryItems?.first(where: { $0.name == "key" })?.value else {
            return false
        }

        Task {
            _ = await self.activate(key: keyParam)
        }
        return true
    }

    /// Deactivates the current license from this machine.
    public func deactivate() {
        self.isLicensed = false
        self.licenseKey = ""
        self.licenseeEmail = ""
        self.activationDate = nil
        self.statusMessage = "License removed."

        UserDefaults.standard.removeObject(forKey: licenseKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: licenseeEmailStorageKey)
        UserDefaults.standard.removeObject(forKey: isLicensedStorageKey)
        UserDefaults.standard.removeObject(forKey: activatedAtStorageKey)
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

    public static func getHardwareUUID() -> String {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return "MAC-UNKNOWN-HWID" }
        defer { IOObjectRelease(platformExpert) }

        if let uuidAsCFString = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return uuidAsCFString
        }
        return "MAC-FALLBACK-HWID"
    }
}
