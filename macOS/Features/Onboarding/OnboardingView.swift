import SwiftUI
import AppKit
import AVFoundation
import Speech

public struct OnboardingView: View {
    @Binding public var isPresented: Bool
    public var onComplete: (([ContextSpace], String) -> Void)?

    @AppStorage("user_name") private var userName: String = ""
    @AppStorage("selected_llm_provider") private var selectedProvider: String = "openrouter"
    @AppStorage("selected_stt_provider") private var selectedSTTProvider: String = "apple_speech"
    @AppStorage("elevenlabs_api_key") private var elevenLabsApiKey: String = ""
    @AppStorage("openrouter_api_key") private var openRouterApiKey: String = ""
    @AppStorage("openrouter_model") private var openRouterModel: String = "anthropic/claude-sonnet-5"
    @AppStorage("openrouter_custom_model") private var openRouterCustomModel: String = ""
    @AppStorage("anthropic_api_key") private var anthropicApiKey: String = ""
    @AppStorage("anthropic_model") private var anthropicModel: String = "claude-3-7-sonnet-20250219"
    @AppStorage("openai_api_key") private var openAIApiKey: String = ""
    @AppStorage("openai_model") private var openAIModel: String = "gpt-4o"
    @AppStorage("custom_llm_url") private var customEndpoint: String = "http://localhost:11434/v1/chat/completions"
    @AppStorage("custom_llm_api_key") private var customApiKey: String = ""
    @AppStorage("custom_llm_model") private var customModel: String = "llama3.3"
    @AppStorage("selected_space_id") private var selectedSpaceId: String = "space-work"

    @ObservedObject private var launchManager = LaunchAtLoginManager.shared

    @State private var currentStep: Int = 1
    @State private var spaces: [ContextSpace] = []
    @State private var selectedSpaceForEditingId: String = "space-work"

    // Space editor fields
    @State private var spaceNames: [String: String] = [:]
    @State private var spaceDescriptions: [String: String] = [:]
    @State private var spaceRetentions: [String: Int] = [:]
    @State private var spacePrompts: [String: String] = [:]

    // Permissions state
    @State private var micPermissionGranted: Bool = false
    @State private var speechPermissionGranted: Bool = false

    public init(isPresented: Binding<Bool>, onComplete: (([ContextSpace], String) -> Void)? = nil) {
        self._isPresented = isPresented
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Progress Bar
            headerStepIndicator
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Step Content
            VStack {
                switch currentStep {
                case 1:
                    welcomeStepView
                case 2:
                    spacesConfigurationStepView
                case 3:
                    aiProvidersStepView
                case 4:
                    permissionsAndFinishStepView
                default:
                    welcomeStepView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            Divider()

            // Footer Navigation Controls
            footerNavigationBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 700, height: 580)
        .onAppear {
            if userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userName = NSFullUserName().isEmpty ? "User" : NSFullUserName()
            }
            initializeSpaces()
            checkMicPermission()
            checkSpeechPermission()
            launchManager.refreshStatus()
        }
    }

    // MARK: - Header Indicator

    private var headerStepIndicator: some View {
        HStack(spacing: 12) {
            stepBadge(step: 1, title: "Welcome")
            lineDivider(active: currentStep > 1)
            stepBadge(step: 2, title: "Spaces & Prompts")
            lineDivider(active: currentStep > 2)
            stepBadge(step: 3, title: "AI Models")
            lineDivider(active: currentStep > 3)
            stepBadge(step: 4, title: "Readiness")
        }
    }

    private func stepBadge(step: Int, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(currentStep == step ? Color.accentColor : (currentStep > step ? Color.green : Color.secondary.opacity(0.3)))
                .frame(width: 20, height: 20)
                .overlay(
                    Group {
                        if currentStep > step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(step)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(currentStep == step ? .white : .secondary)
                        }
                    }
                )
            Text(title)
                .font(.system(size: 12, weight: currentStep == step ? .bold : .medium))
                .foregroundColor(currentStep == step ? .primary : .secondary)
        }
    }

    private func lineDivider(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green : Color.secondary.opacity(0.2))
            .frame(height: 2)
            .frame(maxWidth: 36)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStepView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Welcome to Sidebrief")
                .font(.system(size: 24, weight: .bold))

            Text("Your personal native macOS meeting copilot. Capture dual-audio streams, receive high-precision executive suggestions, and search across your work.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR NAME & EXECUTIVE PROFILE")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 18))
                    TextField("Your Name (e.g. \(NSFullUserName().isEmpty ? "Alex" : NSFullUserName()))", text: $userName)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Sidebrief uses your name in copilot suggestions, action-item delegation, and speaker attribution.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)
            .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 12) {
                spaceHighlightRow(
                    icon: "briefcase.fill",
                    color: .blue,
                    title: "Work",
                    id: "space-work",
                    desc: "Primary workspace for daily meetings, team syncs, technical architecture, and decisions."
                )

                spaceHighlightRow(
                    icon: "plus.square.dashed",
                    color: .purple,
                    title: "Custom Spaces",
                    id: "settings",
                    desc: "Create dedicated isolated spaces in Settings for specialized ventures, clients, or personal topics."
                )
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(12)
            .frame(maxWidth: 560)

            Text("Meetings, notes, and search retrieval are strictly scoped to their respective context space.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private func spaceHighlightRow(icon: String, color: Color, title: String, id: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .fontWeight(.bold)
                    Text("(\(id))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 2: Spaces & Prompts Customization

    private var spacesConfigurationStepView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Configure Context Spaces & Prompts")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Customize how Sidebrief's copilot assists you in each domain. Review names, retention, and persona prompts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Space Selector Tabs
            HStack(spacing: 8) {
                ForEach(spaces) { space in
                    Button(action: {
                        selectedSpaceForEditingId = space.id
                    }) {
                        HStack(spacing: 6) {
                            Text(spaceNames[space.id] ?? space.name)
                                .font(.system(size: 13, weight: selectedSpaceForEditingId == space.id ? .bold : .medium))
                            if selectedSpaceId == space.id {
                                Text("DEFAULT")
                                    .font(.system(size: 9, weight: .heavy))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
                                    .cornerRadius(3)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedSpaceForEditingId == space.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedSpaceForEditingId == space.id ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            // Editor form for selected space
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Space Name:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Space Name", text: Binding(
                                get: { spaceNames[selectedSpaceForEditingId] ?? "" },
                                set: { spaceNames[selectedSpaceForEditingId] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud Retention:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Stepper("\(spaceRetentions[selectedSpaceForEditingId] ?? 365) days", value: Binding(
                                get: { spaceRetentions[selectedSpaceForEditingId] ?? 365 },
                                set: { spaceRetentions[selectedSpaceForEditingId] = $0 }
                            ), in: 30...3650, step: 30)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Description:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Description", text: Binding(
                            get: { spaceDescriptions[selectedSpaceForEditingId] ?? "" },
                            set: { spaceDescriptions[selectedSpaceForEditingId] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Copilot Persona & System Prompt:")
                                .font(.caption)
                                .fontWeight(.bold)
                            Spacer()
                            Button("Reset to Recommended") {
                                resetSpacePromptToTemplate(selectedSpaceForEditingId)
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }

                        TextEditor(text: Binding(
                            get: { spacePrompts[selectedSpaceForEditingId] ?? "" },
                            set: { spacePrompts[selectedSpaceForEditingId] = $0 }
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 110)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }

                    HStack {
                        if selectedSpaceId != selectedSpaceForEditingId {
                            Button("Set as Initial Active Space") {
                                selectedSpaceId = selectedSpaceForEditingId
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Label("This space will be active on startup", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.04))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - Step 3: AI Providers & Models

    private var aiProvidersStepView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("AI Providers & Reasoning Models")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Configure your credentials for real-time speech-to-text and copilot reasoning. Leave blank to explore in offline/mock mode.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live Speech-to-Text (STT)")
                        .fontWeight(.bold)

                    Picker("STT Engine", selection: $selectedSTTProvider) {
                        Text("Apple Speech (Free, Native)").tag("apple_speech")
                        Text("ElevenLabs Scribe v2").tag("elevenlabs")
                        Text("OpenAI Whisper").tag("whisper")
                    }
                    .pickerStyle(.segmented)

                    if selectedSTTProvider == "apple_speech" {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("Built-in macOS On-Device Speech Recognition (Zero API Key, Private & Free)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if selectedSTTProvider == "elevenlabs" {
                        SecureField("ElevenLabs API Key", text: $elevenLabsApiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Uses ElevenLabs Scribe v2 realtime WebSocket streaming with Voice Activity Detection (VAD).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedSTTProvider == "whisper" {
                        SecureField("OpenAI / Groq API Key", text: $openAIApiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Uses OpenAI Whisper or Groq Whisper for cloud transcription.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Executive Reasoning & Suggestions")
                        .fontWeight(.bold)

                    Picker("Provider", selection: $selectedProvider) {
                        Text("OpenRouter").tag("openrouter")
                        Text("Anthropic Direct").tag("anthropic")
                        Text("OpenAI Direct").tag("openai")
                        Text("Custom / Local").tag("custom")
                    }
                    .pickerStyle(.segmented)

                    switch selectedProvider {
                    case "openrouter":
                        VStack(alignment: .leading, spacing: 6) {
                            SecureField("OpenRouter API Key (sk-or-...)", text: $openRouterApiKey)
                                .textFieldStyle(.roundedBorder)

                            Picker("Reasoning Model", selection: $openRouterModel) {
                                Section("Anthropic Claude 5 & 4.x") {
                                    Text("Claude 5 Sonnet (Frontier Flagship)").tag("anthropic/claude-sonnet-5")
                                    Text("Claude 5 Opus (Maximum Reasoning Depth)").tag("anthropic/claude-opus-5")
                                    Text("Claude 4.6 Sonnet (Frontier • 1M Context)").tag("anthropic/claude-sonnet-4.6")
                                    Text("Claude 3.7 Sonnet (Hybrid Thinking)").tag("anthropic/claude-3.7-sonnet")
                                }
                                Section("OpenAI Luna Pro & Frontier") {
                                    Text("GPT-5.6 Luna Pro (Sub-Second Latency • 1M Context)").tag("openai/gpt-5.6-luna-pro")
                                    Text("GPT-Luna Latest (Cost-Efficient Frontier)").tag("openai/gpt-luna-latest")
                                    Text("OpenAI o3-mini (Advanced Reasoning)").tag("openai/o3-mini")
                                    Text("GPT-4o (Multimodal Flagship)").tag("openai/gpt-4o")
                                }
                                Section("Google & Open Weights") {
                                    Text("Gemini 2.0 Flash (Sub-Second)").tag("google/gemini-2.0-flash-001")
                                    Text("DeepSeek R1 (Open Reasoning)").tag("deepseek/deepseek-r1")
                                }
                                Text("Custom Model...").tag("custom")
                            }

                            if openRouterModel == "custom" {
                                TextField("Custom Model ID", text: $openRouterCustomModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                    case "anthropic":
                        VStack(alignment: .leading, spacing: 6) {
                            SecureField("Anthropic API Key (sk-ant-...)", text: $anthropicApiKey)
                                .textFieldStyle(.roundedBorder)

                            Picker("Anthropic Model", selection: $anthropicModel) {
                                Text("Claude 3.7 Sonnet (Hybrid Thinking)").tag("claude-3-7-sonnet-20250219")
                                Text("Claude 3.5 Sonnet (Frontier Coding)").tag("claude-3-5-sonnet-20241022")
                                Text("Claude 3.5 Haiku (Ultra-Fast)").tag("claude-3-5-haiku-20241022")
                                Text("Claude 5 Sonnet (Direct API)").tag("claude-sonnet-5")
                                Text("Claude 5 Opus (Direct API)").tag("claude-opus-5")
                            }
                        }

                    case "openai":
                        VStack(alignment: .leading, spacing: 6) {
                            SecureField("OpenAI API Key (sk-...)", text: $openAIApiKey)
                                .textFieldStyle(.roundedBorder)

                            Picker("OpenAI Model", selection: $openAIModel) {
                                Text("GPT-4o Flagship").tag("gpt-4o")
                                Text("OpenAI o3-mini (Advanced Reasoning)").tag("o3-mini")
                                Text("GPT-4o Mini (Lightweight)").tag("gpt-4o-mini")
                            }
                        }

                    case "custom":
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Endpoint URL (e.g. http://localhost:11434/v1)", text: $customEndpoint)
                                .textFieldStyle(.roundedBorder)
                            SecureField("API Key (optional)", text: $customApiKey)
                                .textFieldStyle(.roundedBorder)
                            TextField("Model Name (e.g. llama3.3)", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                        }

                    default:
                        EmptyView()
                    }

                    Text("Generates 1 concise recommendation (25-50 words) written from your perspective and up to 2 distinct strategic alternatives.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(12)
            .frame(maxWidth: 560)

            Spacer()
        }
    }

    // MARK: - Step 4: Permissions & Launch

    private var permissionsAndFinishStepView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("System Setup & Launch")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Ensure capture permissions are ready and configure macOS system startup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                // Microphone Permission Row
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone Capture (AVFoundation)")
                            .fontWeight(.medium)
                        Text("Records your local side of the meeting in 48kHz mono LPCM.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if micPermissionGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    } else {
                        Button("Allow Microphone") {
                            requestMicPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // Speech Recognition (SFSpeechRecognizer) Row
                HStack {
                    Image(systemName: "waveform.and.mic")
                        .foregroundColor(.teal)
                        .font(.system(size: 18))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech Recognition (SFSpeechRecognizer)")
                            .fontWeight(.medium)
                        Text("Transcribes both tracks locally on-device with zero external API key requirements.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if speechPermissionGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    } else {
                        Button("Allow Speech") {
                            requestSpeechPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // System Audio Permission Row
                HStack {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.purple)
                        .font(.system(size: 18))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio Loopback (ScreenCaptureKit)")
                            .fontWeight(.medium)
                        Text("Transcribes remote participants from Zoom, Meet, Teams, and Slack.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // Launch at Login Toggle
                Toggle("Launch Sidebrief at Login", isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.setEnabled($0) }
                ))
                .fontWeight(.medium)

                Text("Keeps Sidebrief running discreetly in your menu bar so you can join any meeting instantly.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Default Space selection
                HStack {
                    Text("Initial Context Space:")
                        .fontWeight(.medium)
                    Spacer()
                    Picker("", selection: $selectedSpaceId) {
                        ForEach(spaces) { s in
                            Text(spaceNames[s.id] ?? s.name).tag(s.id)
                        }
                    }
                    .frame(width: 200)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(12)
            .frame(maxWidth: 560)

            Spacer()
        }
    }

    // MARK: - Footer Navigation Bar

    private var footerNavigationBar: some View {
        HStack {
            if currentStep > 1 {
                Button("Back") {
                    withAnimation {
                        currentStep -= 1
                    }
                }
            }

            Spacer()

            if currentStep < 4 {
                Button("Continue") {
                    withAnimation {
                        currentStep += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Complete Setup & Launch Sidebrief") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
    }

    // MARK: - Helpers & Data Loading

    private func initializeSpaces() {
        var loaded = LocalDatabaseStore.shared.getContextSpaces()
        if loaded.isEmpty {
            for s in ContextSpace.defaultSpaces {
                LocalDatabaseStore.shared.saveContextSpace(s)
            }
            loaded = LocalDatabaseStore.shared.getContextSpaces()
        }
        self.spaces = loaded

        for s in loaded {
            spaceNames[s.id] = s.name
            spaceDescriptions[s.id] = s.description
            spaceRetentions[s.id] = s.retentionDays
            spacePrompts[s.id] = s.customPrompt
        }
    }

    private func resetSpacePromptToTemplate(_ spaceId: String) {
        if let def = ContextSpace.defaultSpaces.first(where: { $0.id == spaceId }) {
            spacePrompts[spaceId] = def.customPrompt
            spaceNames[spaceId] = def.name
            spaceDescriptions[spaceId] = def.description
            spaceRetentions[spaceId] = def.retentionDays
        }
    }

    private func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        default:
            micPermissionGranted = false
        }
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micPermissionGranted = granted
            }
        }
    }

    private func checkSpeechPermission() {
        let status = SFSpeechRecognizer.authorizationStatus()
        self.speechPermissionGranted = (status == .authorized)
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.speechPermissionGranted = (status == .authorized)
            }
        }
    }

    private func finishOnboarding() {
        let cleanName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            userName = NSFullUserName().isEmpty ? "User" : NSFullUserName()
        } else {
            userName = cleanName
        }

        LocalDatabaseStore.shared.seedDefaultSpeakerProfilesIfNeeded()

        var updatedSpaces: [ContextSpace] = []
        for s in spaces {
            let updated = ContextSpace(
                id: s.id,
                name: spaceNames[s.id] ?? s.name,
                description: spaceDescriptions[s.id] ?? s.description,
                retentionDays: spaceRetentions[s.id] ?? s.retentionDays,
                allowedProviders: s.allowedProviders,
                customPrompt: spacePrompts[s.id] ?? s.customPrompt,
                createdAt: s.createdAt,
                updatedAt: Date()
            )
            LocalDatabaseStore.shared.saveContextSpace(updated)
            updatedSpaces.append(updated)
        }

        NotificationCenter.default.post(name: NSNotification.Name("ContextSpacesDidChange"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("ActiveSpaceDidChange"), object: selectedSpaceId)
        NotificationCenter.default.post(name: NSNotification.Name("SidebriefSettingsDidChange"), object: nil)

        onComplete?(updatedSpaces, selectedSpaceId)
        isPresented = false
    }
}
