import SwiftUI

public struct SoftwareUpdateSheet: View {
    @ObservedObject var updater = UpdateCheckerService.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text(updater.updateAvailable ? "New Version Available" : "Software Update")
                        .font(.headline)

                    if updater.updateAvailable {
                        Text("Sidebrief v\(updater.latestVersion) is now available (you have v\(updater.currentVersion)). Would you like to download it now?")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("You're running the latest version of Sidebrief (v\(updater.currentVersion)).")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if updater.updateAvailable && !updater.releaseNotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Release Notes:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ScrollView {
                        Text(updater.releaseNotes)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 120)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
            }

            HStack {
                Button("Close") {
                    updater.isPresentingUpdateSheet = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if updater.updateAvailable {
                    Button("Download Update (.dmg)") {
                        updater.downloadUpdate()
                        updater.isPresentingUpdateSheet = false
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Check Again") {
                        Task {
                            await updater.checkForUpdates(userInitiated: true)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
