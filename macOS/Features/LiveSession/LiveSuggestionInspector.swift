import SwiftUI
import AppKit

public struct LiveSuggestionInspector: View {
    @Binding public var currentSuggestion: SuggestionCard?
    @Binding public var isPinned: Bool
    public var contextSpaceName: String
    public var currentTranscriptRevision: Int
    public var textScale: TextScalePreference
    public var onPinToggled: (Bool) -> Void
    public var onTriggerHelp: () -> Void
    public var onAskChat: (String) -> Void

    @State private var selectedAlternativeIndex: Int = 0
    @State private var showEvidence: Bool = false
    @State private var chatInput: String = ""
    @State private var copiedNotice: Bool = false
    @State private var isHoveringCard: Bool = false

    public init(
        currentSuggestion: Binding<SuggestionCard?>,
        isPinned: Binding<Bool>,
        contextSpaceName: String,
        currentTranscriptRevision: Int,
        textScale: TextScalePreference,
        onPinToggled: @escaping (Bool) -> Void,
        onTriggerHelp: @escaping () -> Void,
        onAskChat: @escaping (String) -> Void
    ) {
        self._currentSuggestion = currentSuggestion
        self._isPinned = isPinned
        self.contextSpaceName = contextSpaceName
        self.currentTranscriptRevision = currentTranscriptRevision
        self.textScale = textScale
        self.onPinToggled = onPinToggled
        self.onTriggerHelp = onTriggerHelp
        self.onAskChat = onAskChat
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Inspector Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Sidebrief Copilot")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }

                Spacer()

                Text(contextSpaceName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize()

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
                    .fixedSize(horizontal: true, vertical: false)
                    .help(isPinned ? "Unpin suggestion" : "Pin suggestion")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Inspector Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let card = currentSuggestion {
                        suggestionDetailView(card)
                    } else {
                        idleListeningView
                    }
                }
                .padding(14)
            }

            Divider()

            // Quick Prompt Action Chips
            quickPromptPillsBar

            Divider()

            // Quick Chat Bar
            chatComposerBar
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Suggestion Card View

    private func suggestionDetailView(_ card: SuggestionCard) -> some View {
        let isOutdated = currentTranscriptRevision > (card.contextRevision + 2) && !isPinned
        let bodyFontSize = textScale.suggestionBodySize

        return VStack(alignment: .leading, spacing: 12) {
            // Topic Header & Turn Revision
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("CURRENT TOPIC / QUESTION")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.secondary)

                        if card.contextRevision > 0 {
                            Text("• Turn #\(card.contextRevision)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(card.detectedTopicOrQuestion)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(card.triggerReason.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if isOutdated {
                        Text("Discussion moved on")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }

            // Alternatives Tabs with ⌘1, ⌘2, ⌘3 shortcuts
            let options = currentAlternativesList(for: card)
            if options.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<options.count, id: \.self) { idx in
                        Button(action: { selectedAlternativeIndex = idx }) {
                            HStack(spacing: 4) {
                                Text(options[idx].label)
                                Text("⌘\(idx + 1)")
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .opacity(0.7)
                            }
                            .font(.system(size: 11, weight: selectedAlternativeIndex == idx ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selectedAlternativeIndex == idx ? Color.accentColor : Color.primary.opacity(0.08))
                            .foregroundColor(selectedAlternativeIndex == idx ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                    }
                }
            }

            // Selected Response Text
            let selectedAlt = options[min(selectedAlternativeIndex, options.count - 1)]
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedAlt.text)
                    .font(.system(size: bodyFontSize, weight: .regular))
                    .lineSpacing(4)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)

                if let rationale = selectedAlt.rationale, !rationale.isEmpty {
                    Text("Why: \(rationale)")
                        .font(.system(size: 11.5, weight: .regular))
                        .italic()
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHoveringCard ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .onHover { hovering in
                self.isHoveringCard = hovering
            }

            // Evidence Bar
            HStack {
                Text(card.evidenceCategory.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(evidenceColor(for: card.evidenceCategory).opacity(0.15))
                    .foregroundColor(evidenceColor(for: card.evidenceCategory))
                    .clipShape(Capsule())

                Spacer()

                if !card.evidenceQuotes.isEmpty {
                    Button(action: { showEvidence.toggle() }) {
                        HStack(spacing: 4) {
                            Text(showEvidence ? "Hide Evidence" : "\(card.evidenceQuotes.count) Sources")
                                .font(.system(size: 10.5))
                            Image(systemName: showEvidence ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5))
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
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.primary)
                            Text("\"\(quote.snippet)\"")
                                .font(.system(size: 10.5))
                                .italic()
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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
                        .font(.system(size: 10.5))
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
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)

                Spacer()

                Button(action: {
                    currentSuggestion = nil
                }) {
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Idle State

    private var idleListeningView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)

            Text("Listening to conversation...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            Text("Suggestions appear automatically every ~10s or when someone asks a question. You can also press Control-Option-Space anytime.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            Button(action: onTriggerHelp) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Help Me Answer Now")
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Quick Prompt Action Chips

    private var quickPromptPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                quickPromptChip("Clarify last point")
                quickPromptChip("Summarize decisions so far")
                quickPromptChip("Fact-check this")
                quickPromptChip("What should I ask next?")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func quickPromptChip(_ prompt: String) -> some View {
        Button(action: {
            onAskChat(prompt)
        }) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 8))
                Text(prompt)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.06))
            .foregroundColor(.primary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Chat Composer Bar

    private var chatComposerBar: some View {
        HStack(spacing: 8) {
            TextField("Ask copilot about the meeting...", text: $chatInput)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
