import SwiftUI

/// User configurable text scaling preference for Live Session & Inspector
public enum TextScalePreference: String, CaseIterable, Identifiable, Sendable {
    case compact = "compact"
    case regular = "regular"
    case spacious = "spacious"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact: return "Compact (11pt)"
        case .regular: return "Regular (13pt)"
        case .spacious: return "Spacious (15pt)"
        }
    }

    public var transcriptBodySize: CGFloat {
        switch self {
        case .compact: return 11.5
        case .regular: return 13.5
        case .spacious: return 15.5
        }
    }

    public var suggestionBodySize: CGFloat {
        switch self {
        case .compact: return 12.0
        case .regular: return 14.0
        case .spacious: return 16.5
        }
    }

    public var titleSize: CGFloat {
        switch self {
        case .compact: return 12.0
        case .regular: return 13.5
        case .spacious: return 15.0
        }
    }
}
