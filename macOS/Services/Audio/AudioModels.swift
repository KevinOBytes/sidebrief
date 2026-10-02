import Foundation

public struct AudioLevelMeter: Sendable {
    public var peakPower: Float // dB, typically -60.0 to 0.0
    public var averagePower: Float // RMS dB
    public var linearLevel: Float // Normalized 0.0 to 1.0 for UI meters

    public init(peakPower: Float = -60.0, averagePower: Float = -60.0, linearLevel: Float = 0.0) {
        self.peakPower = peakPower
        self.averagePower = averagePower
        self.linearLevel = linearLevel
    }

    public static func from(rms: Float, peak: Float) -> AudioLevelMeter {
        // Convert linear amplitude to decibels
        let avgDb = rms > 0.00001 ? 20.0 * log10(rms) : -60.0
        let peakDb = peak > 0.00001 ? 20.0 * log10(peak) : -60.0

        // Linear display factor from 0.0 to 1.0 (clamped)
        let linear = max(0.0, min(1.0, (avgDb + 50.0) / 50.0))
        return AudioLevelMeter(peakPower: peakDb, averagePower: avgDb, linearLevel: linear)
    }
}

public enum AudioCaptureState: String, Sendable {
    case idle
    case initializing
    case capturing
    case paused
    case degraded
    case failed
}

public enum SystemCaptureScope: Sendable, Hashable {
    case wholeSystem
    case selectedApplication(bundleId: String, appName: String)
}

public struct AudioDeviceItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}
