import SwiftUI
import AppKit

/// SpeakerColorPalette provides deterministic, accessible, visually distinct colors
/// for meeting participants across Live Session, Past Meetings, and Exported Documents.
public enum SpeakerColorPalette {
    public struct SpeakerColorTheme: Sendable {
        public let name: String
        public let primaryColor: Color
        public let nsColor: NSColor
        public let bgOpacity: Double
    }

    // 8 distinct, accessible, harmonious themes
    private static let themes: [SpeakerColorTheme] = [
        SpeakerColorTheme(name: "Blue", primaryColor: Color.blue, nsColor: .systemBlue, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Purple", primaryColor: Color.purple, nsColor: .systemPurple, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Teal", primaryColor: Color.teal, nsColor: .systemTeal, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Indigo", primaryColor: Color.indigo, nsColor: .systemIndigo, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Orange", primaryColor: Color.orange, nsColor: .systemOrange, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Green", primaryColor: Color.green, nsColor: .systemGreen, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Pink", primaryColor: Color.pink, nsColor: .systemPink, bgOpacity: 0.15),
        SpeakerColorTheme(name: "Brown", primaryColor: Color.brown, nsColor: .systemBrown, bgOpacity: 0.15),
    ]

    /// Returns the deterministic color for a given speaker label
    public static func color(for speaker: String) -> Color {
        theme(for: speaker).primaryColor
    }

    /// Returns the NSColor equivalent for AppKit / PDF rendering
    public static func nsColor(for speaker: String) -> NSColor {
        theme(for: speaker).nsColor
    }

    /// Returns the full theme object
    public static func theme(for speaker: String) -> SpeakerColorTheme {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "You" || trimmed.caseInsensitiveCompare("You") == .orderedSame {
            return themes[0] // Blue for You
        }

        // Hash speaker name into deterministic index 1..7
        var hash: UInt32 = 5381
        for byte in trimmed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        let index = 1 + Int(hash % UInt32(themes.count - 1))
        return themes[index]
    }
}
