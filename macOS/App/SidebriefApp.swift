import SwiftUI
import AppKit
import SidebriefCore

@main
public struct SidebriefApp: App {
    @StateObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var updater = UpdateCheckerService.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var selectedSidebarItem: SidebarItem? = .live
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding: Bool = false
    @State private var isShowingOnboarding: Bool = false

    public init() {}

    public var body: some Scene {
        // Main Window Scene
        WindowGroup {
            NavigationSplitView {
                sidebarView
            } detail: {
                detailView
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        selectedSidebarItem = .live
                        if coordinator.captureState == .idle || coordinator.captureState == .failed {
                            Task { await coordinator.startMeeting() }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text("New Meeting")
                        }
                    }
                    .help("Start New Meeting (⌘N)")
                }
            }
            .sheet(isPresented: $isShowingOnboarding) {
                OnboardingView(isPresented: $isShowingOnboarding) { configuredSpaces, activeSpaceId in
                    hasCompletedOnboarding = true
                    coordinator.reloadSpaces()
                    if let active = coordinator.availableSpaces.first(where: { $0.id == activeSpaceId }) {
                        coordinator.setActiveSpace(active)
                    }
                }
            }
            .sheet(isPresented: $updater.isPresentingUpdateSheet) {
                SoftwareUpdateSheet()
            }
            .onOpenURL { url in
                _ = licenseManager.handleActivationUrl(url)
            }
            .onAppear {
                if !hasCompletedOnboarding {
                    isShowingOnboarding = true
                }
                Task {
                    // Check for updates quietly in background on launch
                    await updater.checkForUpdates(userInitiated: false)
                }
            }
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Meeting") {
                    selectedSidebarItem = .live
                    if coordinator.captureState == .idle || coordinator.captureState == .failed {
                        Task { await coordinator.startMeeting() }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Sidebrief") {
                Button("Run Setup Wizard...") {
                    isShowingOnboarding = true
                }

                Button("Check for Updates...") {
                    Task {
                        await updater.checkForUpdates(userInitiated: true)
                    }
                }
            }

            CommandMenu("Copilot") {
                Button("Help Me Answer") {
                    coordinator.triggerImmediateHelp()
                }
                .keyboardShortcut(" ", modifiers: [.control, .option])

                Button("Toggle Floating Assistant") {
                    coordinator.toggleFloatingPanel()
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
            }
        }

        // Menu Bar Scene
        MenuBarExtra {
            // Status & Active Space Header
            if coordinator.captureState == .capturing {
                Text("🔴 Recording (\(coordinator.recordingDurationFormatted))")
                Text("Space: \(coordinator.activeSpace.name)")
            } else if coordinator.captureState == .paused {
                Text("⏸ Paused (\(coordinator.recordingDurationFormatted))")
                Text("Space: \(coordinator.activeSpace.name)")
            } else {
                Text("⚪️ Idle — Ready to Record")
                Text("Active Space: \(coordinator.activeSpace.name)")
            }

            Divider()

            // Recording Controls
            if coordinator.captureState == .capturing || coordinator.captureState == .degraded {
                Button("Pause Recording") {
                    coordinator.pauseMeeting()
                }
                Button("Stop & Finalize Meeting") {
                    Task { await coordinator.stopMeeting() }
                }
            } else if coordinator.captureState == .paused {
                Button("Resume Recording") {
                    coordinator.resumeMeeting()
                }
                Button("Stop & Finalize Meeting") {
                    Task { await coordinator.stopMeeting() }
                }
            } else {
                Button("Start New Meeting (⌘N)") {
                    Task {
                        await coordinator.startMeeting()
                    }
                }
            }

            Divider()

            // Executive Copilot
            Button("Help Me Answer (⌃⌥Space)") {
                coordinator.triggerImmediateHelp()
            }

            Button("Toggle Floating Assistant (⌥⌘H)") {
                coordinator.toggleFloatingPanel()
            }

            Divider()

            // Context Spaces Menu
            Menu("Context Space (\(coordinator.activeSpace.name))") {
                ForEach(coordinator.availableSpaces) { space in
                    Button(action: {
                        coordinator.setActiveSpace(space)
                    }) {
                        HStack {
                            Text(space.name)
                            if space.id == coordinator.activeSpace.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            // Window Management & Preferences
            Button("Open Sidebrief Window") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Preferences...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Run Setup Wizard...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
                isShowingOnboarding = true
            }

            Divider()

            Button("Quit Sidebrief") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: coordinator.captureState == .capturing ? "record.circle.fill" : (coordinator.captureState == .paused ? "pause.circle.fill" : "waveform.circle"))
                if coordinator.captureState == .capturing {
                    Text(coordinator.recordingDurationFormatted)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
            }
        }

        // Settings Window Scene
        Settings {
            SettingsView()
        }
    }

    // MARK: - Sidebar

    public enum SidebarItem: Hashable {
        case live
        case pastMeetings
        case memory
        case settings
    }

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Prominent "New Meeting" Action Button at top of sidebar
            Button(action: {
                selectedSidebarItem = .live
                if coordinator.captureState == .idle || coordinator.captureState == .failed {
                    Task { await coordinator.startMeeting() }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                    Text("New Meeting")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .opacity(0.7)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            List(selection: $selectedSidebarItem) {
                Section("Context Space") {
                    Picker("Active Space", selection: Binding(
                        get: { coordinator.activeSpace.id },
                        set: { newId in
                            if let sp = coordinator.availableSpaces.first(where: { $0.id == newId }) {
                                coordinator.setActiveSpace(sp)
                            }
                        }
                    )) {
                        ForEach(coordinator.availableSpaces) { space in
                            Text(space.name).tag(space.id)
                        }
                    }
                    .labelsHidden()
                }

                Section("Session") {
                    NavigationLink(value: SidebarItem.live) {
                        Label("Live Meeting", systemImage: "waveform")
                    }
                }

                Section("History") {
                    NavigationLink(value: SidebarItem.pastMeetings) {
                        Label("Past Meetings (\(coordinator.pastMeetings.count))", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section("Knowledge") {
                    NavigationLink(value: SidebarItem.memory) {
                        Label("Memory & Context (\(coordinator.memoryFacts.count))", systemImage: "brain.head.profile")
                    }
                }

                Section("Preferences") {
                    NavigationLink(value: SidebarItem.settings) {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 200)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedSidebarItem ?? .live {
        case .live:
            LiveSessionView(
                meeting: $coordinator.currentMeeting,
                transcriptSegments: $coordinator.transcriptSegments,
                micMeter: $coordinator.micMeter,
                systemMeter: $coordinator.systemMeter,
                captureState: $coordinator.captureState,
                currentSuggestion: $coordinator.currentSuggestion,
                isPinned: $coordinator.isPinned,
                contextSpaceName: coordinator.activeSpace.name,
                tokenUsage: coordinator.currentMeetingTokenUsage,
                onStartRecording: {
                    Task {
                        await coordinator.startMeeting()
                    }
                },
                onPauseRecording: {
                    coordinator.pauseMeeting()
                },
                onResumeRecording: {
                    coordinator.resumeMeeting()
                },
                onStopRecording: {
                    Task { await coordinator.stopMeeting() }
                },
                onTriggerHelp: {
                    coordinator.triggerImmediateHelp()
                },
                onPinToggled: { pinned in
                    if let id = coordinator.currentSuggestion?.id {
                        coordinator.togglePinSuggestion(cardId: id, isPinned: pinned)
                    }
                },
                onRenameSpeaker: { oldLabel, newLabel in
                    coordinator.renameSpeaker(oldLabel: oldLabel, newLabel: newLabel)
                },
                onAskChat: { prompt in
                    coordinator.handleInMeetingChat(prompt: prompt)
                }
            )

        case .pastMeetings:
            PastMeetingsView(
                pastMeetings: $coordinator.pastMeetings,
                selectedPastMeeting: $coordinator.selectedPastMeeting,
                summary: $coordinator.pastMeetingSummary,
                transcriptSegments: $coordinator.pastMeetingSegments,
                playbackOffsetMs: $coordinator.playbackOffsetMs,
                isPlaying: $coordinator.isPlaying,
                availableSpaces: coordinator.availableSpaces,
                onSelectMeeting: { meeting in
                    coordinator.selectPastMeeting(meeting)
                },
                onDeleteMeeting: { id in
                    coordinator.deletePastMeeting(id: id)
                },
                onPlayPause: {
                    if coordinator.isPlaying {
                        coordinator.playbackEngine.pause()
                        coordinator.isPlaying = false
                    } else {
                        try? coordinator.playbackEngine.play()
                        coordinator.isPlaying = true
                    }
                },
                onSeek: { offset in
                    try? coordinator.playbackEngine.seek(to: offset)
                },
                onExportMarkdown: {
                    exportMeetingAsMarkdown()
                },
                onExportJSON: {
                    exportMeetingAsJSON()
                },
                onExportSRT: {
                    exportMeetingAsSRT()
                },
                onSearchMeetings: { query, spaceId in
                    coordinator.searchMeetings(query: query, spaceId: spaceId)
                },
                onStartNewMeeting: {
                    selectedSidebarItem = .live
                    if coordinator.captureState == .idle || coordinator.captureState == .failed {
                        Task { await coordinator.startMeeting() }
                    }
                }
            )

        case .memory:
            MemoryManagerView(
                activeSpaceId: Binding(
                    get: { coordinator.activeSpace.id },
                    set: { newId in
                        if let sp = coordinator.availableSpaces.first(where: { $0.id == newId }) {
                            coordinator.setActiveSpace(sp)
                        }
                    }
                ),
                memoryFacts: $coordinator.memoryFacts,
                onSaveFact: { fact in
                    coordinator.saveMemoryFact(fact)
                },
                onDeleteFact: { id in
                    coordinator.deleteMemoryFact(id: id)
                },
                onBootstrapImport: { text in
                    coordinator.importBootstrapMemory(text: text)
                }
            )

        case .settings:
            SettingsView()
        }
    }

    // MARK: - Exports

    private func exportMeetingAsMarkdown() {
        guard let meeting = coordinator.selectedPastMeeting ?? coordinator.pastMeetings.first else { return }
        var md = "# \(meeting.title)\n\n"
        md += "**Date:** \(meeting.createdAt.formatted())\n"
        md += "**State:** \(meeting.state.rawValue)\n\n"

        if let sum = coordinator.pastMeetingSummary {
            md += "## Executive Summary\n\(sum.overview)\n\n"
            if !sum.keyPoints.isEmpty {
                md += "## Key Discussion Points\n"
                for pt in sum.keyPoints { md += "- \(pt)\n" }
                md += "\n"
            }
            if !sum.decisions.isEmpty {
                md += "## Confirmed Decisions\n"
                for d in sum.decisions { md += "- **\(d.title)**: \(d.rationale)\n" }
                md += "\n"
            }
        }

        md += "## Transcript\n"
        for s in coordinator.pastMeetingSegments {
            md += "**\(s.speakerLabel)**: \(s.text)\n\n"
        }

        saveTextFile(content: md, filename: "\(meeting.title).md")
    }

    private func exportMeetingAsJSON() {
        guard let meeting = coordinator.selectedPastMeeting ?? coordinator.pastMeetings.first else { return }
        let payload: [String: Any] = [
            "id": meeting.id,
            "title": meeting.title,
            "createdAt": meeting.createdAt.ISO8601Format(),
            "transcript": coordinator.pastMeetingSegments.map { [
                "speaker": $0.speakerLabel,
                "text": $0.text,
                "startOffsetMs": $0.startOffsetMs,
                "endOffsetMs": $0.endOffsetMs
            ]}
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonStr = String(data: data, encoding: .utf8) {
            saveTextFile(content: jsonStr, filename: "\(meeting.title).json")
        }
    }

    private func exportMeetingAsSRT() {
        guard let meeting = coordinator.selectedPastMeeting ?? coordinator.pastMeetings.first else { return }
        var srt = ""
        for (i, seg) in coordinator.pastMeetingSegments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(seg.startOffsetMs)) --> \(formatSRTTime(seg.endOffsetMs))\n"
            srt += "\(seg.speakerLabel): \(seg.text)\n\n"
        }
        saveTextFile(content: srt, filename: "\(meeting.title).srt")
    }

    private func formatSRTTime(_ ms: Int64) -> String {
        let hours = ms / 3600000
        let minutes = (ms % 3600000) / 60000
        let seconds = (ms % 60000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    private func saveTextFile(content: String, filename: String) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
