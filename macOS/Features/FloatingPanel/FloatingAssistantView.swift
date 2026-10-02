import SwiftUI
import AppKit

public struct FloatingAssistantView: View {
    @Binding public var currentSuggestion: SuggestionCard?
    @Binding public var isPinned: Bool
    @Binding public var contextSpaceName: String
    public var isCaptureDegraded: Bool = false
    public var tokenUsage: TokenUsage = TokenUsage()
    public var onPinToggled: (Bool) -> Void
    public var onDismiss: () -> Void
    public var onRequestImmediateHelp: () -> Void
    public var onAskChat: (String) -> Void

    @State private var selectedAlternativeIndex: Int = 0 // 0 = primary, 1 = alt 1, 2 = alt 2
    @State private var showEvidence: Bool = false
    @State private var chatInput: String = ""
    @State private var copiedNotice: Bool = false

    public init(
        currentSuggestion: Binding<SuggestionCard?>,
        isPinned: Binding<Bool>,
        contextSpaceName: Binding<String>,
        isCaptureDegraded: Bool = false,
        tokenUsage: TokenUsage = TokenUsage(),
        onPinToggled: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onRequestImmediateHelp: @escaping () -> Void,
        onAskChat: @escaping (String) -> Void
    ) {
        self._currentSuggestion = currentSuggestion
        self._isPinned = isPinned
        self._contextSpaceName = contextSpaceName
        self.isCaptureDegraded = isCaptureDegraded
        self.tokenUsage = tokenUsage
        self.onPinToggled = onPinToggled
        self.onDismiss = onDismiss
        self.onRequestImmediateHelp = onRequestImmediateHelp
        self.onAskChat = onAskChat
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            if isCaptureDegraded {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("Single-mic mode. To capture remote voices, enable Screen Recording.")
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Fix...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            // Main Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let card = currentSuggestion {
                        suggestionCardView(card)
                    } else {
                        idleListeningView
                    }
                }
                .padding(16)
            }

            Divider()

            // Quick Chat Bar
            chatBar
        }
        .frame(minWidth: 380, minHeight: 450)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Sidebrief")
                    .font(.system(size: 13, weight: .bold))
                Text("•")
                    .foregroundColor(.secondary)
                Text(contextSpaceName)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())

                // Compact Token & Cost Badge
                if tokenUsage.estimatedCostUSD > 0 || tokenUsage.totalTokens > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 9))
                        Text(String(format: "$%.3f", tokenUsage.estimatedCostUSD))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            Spacer()

            if currentSuggestion != nil {
                Button(action: {
                    isPinned.toggle()
                    onPinToggled(isPinned)
                }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundColor(isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin suggestion" : "Pin suggestion")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func suggestionCardView(_ card: SuggestionCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Topic Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CURRENT QUESTION / TOPIC")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(card.detectedTopicOrQuestion)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer()

                // Trigger badge
                Text(card.triggerReason.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Alternatives Tabs
            let options = currentAlternativesList(for: card)
            if options.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<options.count, id: \.self) { idx in
                        Button(action: { selectedAlternativeIndex = idx }) {
                            Text(options[idx].label)
                                .font(.system(size: 11, weight: selectedAlternativeIndex == idx ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedAlternativeIndex == idx ? Color.accentColor : Color.primary.opacity(0.08))
                                .foregroundColor(selectedAlternativeIndex == idx ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Selected Response Text
            let selectedAlt = options[min(selectedAlternativeIndex, options.count - 1)]
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedAlt.text)
                    .font(.system(size: 13, weight: .regular))
                    .lineSpacing(4)
                    .foregroundColor(.primary)

                if let rationale = selectedAlt.rationale, !rationale.isEmpty {
                    Text("Why: \(rationale)")
                        .font(.system(size: 11, weight: .regular))
                        .italic()
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Evidence Bar
            HStack {
                Text(card.evidenceCategory.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(evidenceColor(for: card.evidenceCategory).opacity(0.15))
                    .foregroundColor(evidenceColor(for: card.evidenceCategory))
                    .clipShape(Capsule())

                Spacer()

                if !card.evidenceQuotes.isEmpty {
                    Button(action: { showEvidence.toggle() }) {
                        HStack(spacing: 4) {
                            Text(showEvidence ? "Hide Evidence" : "\(card.evidenceQuotes.count) Sources")
                                .font(.system(size: 11))
                            Image(systemName: showEvidence ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Expandable Evidence Drawer
            if showEvidence && !card.evidenceQuotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.evidenceQuotes) { quote in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.sourceTitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.primary)
                            Text("\"\(quote.snippet)\"")
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // Uncertainty Note
            if let note = card.uncertaintyNote {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Action Buttons
            HStack(spacing: 12) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedAlt.text, forType: .string)
                    copiedNotice = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedNotice = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedNotice ? "checkmark" : "doc.on.doc")
                        Text(copiedNotice ? "Copied!" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    private var idleListeningView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .symbolEffect(.pulse)

            Text("Listening to conversation...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            Text("Suggestions appear automatically every ~10s or when someone asks a question. You can also press Control-Option-Space anytime.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button(action: onRequestImmediateHelp) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Help Me Answer Now")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var chatBar: some View {
        HStack(spacing: 8) {
            TextField("Ask copilot anything...", text: $chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    submitChat()
                }

            Button(action: submitChat) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(chatInput.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private func submitChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatInput = ""
        onAskChat(text)
    }

    private func currentAlternativesList(for card: SuggestionCard) -> [SuggestionAlternative] {
        var list = [card.primaryResponse]
        list.append(contentsOf: card.alternatives)
        return list
    }

    private func evidenceColor(for category: EvidenceCategory) -> Color {
        switch category {
        case .supportedBySource: return .green
        case .basedOnDiscussion: return .blue
        case .inference: return .purple
        case .needsVerification: return .orange
        }
    }
}

// MARK: - Visual Effect View for AppKit Glass Effect

public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    public func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
