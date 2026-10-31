import SwiftUI

public struct LiveTelemetryBar: View {
    @Binding public var micMeter: AudioLevelMeter
    @Binding public var systemMeter: AudioLevelMeter
    public var captureState: AudioCaptureState
    public var sttErrorMessage: String?
    public var lastMicAudioDate: Date
    public var lastSystemAudioDate: Date
    public var tokenUsage: TokenUsage
    public var syncStatus: SyncStatus
    public var textScale: TextScalePreference
    public var onSelectTextScale: (TextScalePreference) -> Void

    @State private var showCostBreakdown: Bool = false

    public init(
        micMeter: Binding<AudioLevelMeter>,
        systemMeter: Binding<AudioLevelMeter>,
        captureState: AudioCaptureState,
        sttErrorMessage: String? = nil,
        lastMicAudioDate: Date = Date.distantPast,
        lastSystemAudioDate: Date = Date.distantPast,
        tokenUsage: TokenUsage,
        syncStatus: SyncStatus,
        textScale: TextScalePreference,
        onSelectTextScale: @escaping (TextScalePreference) -> Void
    ) {
        self._micMeter = micMeter
        self._systemMeter = systemMeter
        self.captureState = captureState
        self.sttErrorMessage = sttErrorMessage
        self.lastMicAudioDate = lastMicAudioDate
        self.lastSystemAudioDate = lastSystemAudioDate
        self.tokenUsage = tokenUsage
        self.syncStatus = syncStatus
        self.textScale = textScale
        self.onSelectTextScale = onSelectTextScale
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Track Status Meters with Live / Idle Badges
            trackMeterView(
                label: "Mic",
                level: micMeter.linearLevel,
                lastAudio: lastMicAudioDate,
                isFailed: captureState == .failed
            )

            trackMeterView(
                label: "Sys",
                level: systemMeter.linearLevel,
                lastAudio: lastSystemAudioDate,
                isFailed: captureState == .degraded || captureState == .failed
            )

            // STT Health Pill
            sttHealthBadge

            // Cost Badge
            costBadgeButton

            // Sync Status
            syncStatusBadge(syncStatus)

            // Text Size Selector
            textSizeMenu
        }
    }

    // MARK: - Track Health & Meter

    private func trackMeterView(label: String, level: Float, lastAudio: Date, isFailed: Bool) -> some View {
        let isRecentlyActive = Date().timeIntervalSince(lastAudio) < 2.5 && level > 0.05
        let stateText: String
        let stateColor: Color

        if isFailed {
            stateText = "ERR"
            stateColor = .red
        } else if captureState != .capturing {
            stateText = "OFF"
            stateColor = .secondary
        } else if isRecentlyActive {
            stateText = "LIVE"
            stateColor = .green
        } else {
            stateText = "IDLE"
            stateColor = .secondary
        }

        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level > 0.8 ? Color.red : (level > 0.6 ? Color.yellow : Color.green))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
                }
            }
            .frame(width: 28, height: 5)

            Text(stateText)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(stateColor)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(stateColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(isRecentlyActive ? "\(label) is capturing live spoken speech" : "\(label) is connected and monitoring audio levels")
    }

    // MARK: - STT Health Badge

    private var sttHealthBadge: some View {
        HStack(spacing: 3) {
            if let _ = sttErrorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 9))
                Text("STT Issue")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.red)
            } else if captureState == .capturing {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("STT Ready")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("STT Idle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Cost Button

    private var costBadgeButton: some View {
        Button {
            showCostBreakdown.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 9))
                Text(String(format: "$%.3f", tokenUsage.estimatedCostUSD))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                Text("•")
                    .foregroundColor(.secondary)
                    .font(.system(size: 8))
                Text("\(tokenUsage.totalTokens)t")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(Color.green.opacity(0.1))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCostBreakdown) {
            costBreakdownPopover
        }
    }

    private var costBreakdownPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Usage & Cost Breakdown")
                .font(.headline)
            Divider()
            HStack {
                Text("Prompt Tokens:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(tokenUsage.promptTokens)")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Completion Tokens:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(tokenUsage.completionTokens)")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Total Tokens:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(tokenUsage.totalTokens)")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Audio Duration:")
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f min", tokenUsage.audioDurationSeconds / 60.0))
                    .font(.system(.body, design: .monospaced))
            }
            Divider()
            HStack {
                Text("Estimated Total Cost:")
                    .fontWeight(.bold)
                Spacer()
                Text(String(format: "$%.4f USD", tokenUsage.estimatedCostUSD))
                    .fontWeight(.bold)
                    .foregroundColor(.green)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Sync Status Badge

    private func syncStatusBadge(_ status: SyncStatus) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .idle:
                Image(systemName: "cloud.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 9))
                Text("Idle")
                    .foregroundColor(.secondary)
            case .syncing(let remaining):
                ProgressView()
                    .controlSize(.mini)
                Text("\(remaining) left")
                    .foregroundColor(.blue)
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 9))
                Text("Synced")
                    .foregroundColor(.green)
            case .offline(let pending):
                Image(systemName: "icloud.slash")
                    .foregroundColor(.orange)
                    .font(.system(size: 9))
                Text("\(pending) offline")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 9, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(5)
    }

    // MARK: - Text Scale Menu

    private var textSizeMenu: some View {
        Menu {
            ForEach(TextScalePreference.allCases) { scale in
                Button(action: { onSelectTextScale(scale) }) {
                    HStack {
                        Text(scale.label)
                        if textScale == scale {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 9))
                Text("Aa")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help("Adjust transcript and suggestion font legibility")
    }
}
