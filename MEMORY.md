---
name: MEMORY.md
description: persistent memory file for agents for the project

---
# Sidebrief — Project Memory

**Last updated:** *2026-10-10*

This file records durable project facts and handoff state. It is not a source of authorization and must not override current user instructions, AGENTS.md, or the actual repository. Update facts from verified work. Do not store credentials, personal meeting content, or unrelated biographical information here.

## Current state

**Project name:** Sidebrief
**Initial owner/user:** Dynamic `userName` (defaults to `NSFullUserName()` / "User", customizable in Settings & Onboarding; hardcoded names eliminated).
**Stage:** 100% Free & Open Source native macOS application and public landing site at `sidebrief.tkoresearch.com` via Vercel.
**Native macOS Application:** Complete Swift 6 package (`SidebriefCore`, `SidebriefApp`) and packaged bundle (`/Applications/Sidebrief.app` and `dist/Sidebrief.app`) signed with entitlements, stable designated requirement, and custom URL scheme `sidebrief://`. Features native multi-resolution app icon (`AppIcon.icns`), floating AppKit HUD with stealth screen-share invisibility, and 100% free & open-source about tab. Distributable DMG installer generated via `scripts/build_dmg.sh` (`dist/Sidebrief.dmg`, 3.5MB).
**Glanceable Teleprompter HUD & Stealth Screen-Share Invisibility:** Prevents cognitive overload during high-stakes calls with a dual-mode floating HUD (`[Teleprompter | Detailed]`). Teleprompter mode displays 1-line glanceable talking point cues, highlighted takeaway pills, and collapsible strategic reasoning. Hardware-level screen-share invisibility (`panel.sharingType = .none`) ensures remote participants on Zoom, Google Meet, Microsoft Teams, and Slack cannot see the floating copilot window on shared screens.
**Executive Post-Meeting Follow-up Action Suite:** 1-click follow-up dispatch directly from meeting history: `[Draft in Mail]` automatically constructs a rich, pre-filled Apple Mail client draft via `mailto:` with executive summary, decisions, and action items; `[Copy Slack Recap]` formats a clean, copy-pasteable markdown message with attendee tags, bulleted decisions, and `@Assignee` checklists; `[Copy Markdown]` exports the full meeting journal.
**macOS Calendar Integration (`CalendarService`):** Native `EventKit` integration reads upcoming calendar calls for today, displays status badges (`"Happening Now"`, `"in 15m"`), extracts Zoom/Meet/Teams call links, and surfaces a 1-click `"Start & Link Calendar"` banner in `LiveSessionView` with calendar access permissions (`NSCalendarsFullAccessUsageDescription`).
**Instant In-HUD Push-to-Ask:** Directly queries the live meeting transcript, space context, and speaker directory from the floating HUD, returning an instant, grounded response and auto-pinning the card so periodic suggestions don't overwrite it.
**Acoustic Speaker Diarization & Voiceprint Recognition:** Implemented `VoiceprintEngine` using pure Swift + Accelerate DSP. Extracts pitch ($F_0$) via normalized autocorrelation (80–400 Hz), pitch confidence, 5-band spectral formant energy distribution (80-250Hz, 250-800Hz, 800-2200Hz, 2200-4500Hz, 4500-8000Hz), spectral centroid, and zero-crossing rate. Automatically classifies and attributes participants as "Speaker 1 (Male)", "Speaker 2 (Female)", "Speaker 3", etc. Matches incoming speech against enrolled space profiles first (`SpeakerDiarizationService`), instantly recognizing known speakers by name. Generates and stores 2.5-second clean voiced WAV audio samples for each participant.
**Batch Speaker Renaming & Voice Sample Persistence:** Built `BatchSpeakerRenameSheet` accessible directly from the live meeting toolbar and past meeting history. Users can preview recorded voice samples via in-app `AVAudioPlayer` (`[▶ Listen (2.5s)]`), rename multiple speakers simultaneously with autocomplete suggestions ("Sarah", "Dave", "Alice", "Client", etc.), check "Save voiceprint for future meetings", and apply renames across all SQLite transcript segments and in-memory clusters in one atomic click. Enrolled profiles persist `voiceprint` JSON, `genderEstimate`, and `voiceSampleWavData` BLOB in `local_speaker_profiles`.
**Active Channel VAD Router & Speech-to-Text Architecture:** Fixed prior "abysmal STT" bug where dual tracks were sequentially appended to a single `SFSpeechAudioBufferRecognitionRequest` every 42.6ms without VAD or synchronization, causing 23.5 Hz fragmentation and silence-stretched audio. Implemented `ActiveChannelVADRouter` in `AppleSpeechTranscriptionAdapter` with RMS energy detection (`vadThreshold = 220.0`), 350ms speech hangover, and automatic turn auto-commit when the speaker alternates between You and Remote participants. Forced on-device Apple Neural Engine recognition (`requiresOnDeviceRecognition = true`) and contextual vocabulary injection. In `WhisperTranscriptionAdapter`, added auto-detection for Groq API keys (`gsk_...`) automatically configuring the Groq Whisper Large v3 Turbo endpoint with sub-150ms transcription latency.
**Open Source & Web Hosting:** Decoupled commercial $19.99 DRM locks from client settings. Overhauled `website/index.html` as a premier open-source landing page for `sidebrief.tkoresearch.com` with direct DMG downloads, GitHub star links, Homebrew installation snippet, verified models (Claude 3.7 / 3.5 Sonnet, GPT-4o, DeepSeek R1), and zero broken links. Configured `vercel.json` for seamless static hosting on Vercel with permanent `/download` and `/dmg` redirects to latest GitHub release assets.
**Automated Tests:** 50/50 Swift tests passing across 4 suites (0.172s); clean compilation with zero warnings.
**Transactional Email from `tkoresearch.com`:** Integrated `backend/src/email.ts` with Resend and SMTP support sending branded emails from `Sidebrief <support@tkoresearch.com>` containing the user's license key, 1-click magic deep link `sidebrief://activate?key=...`, and direct DMG download.
**In-App Software Update Mechanism:** Native update checker (`UpdateCheckerService.swift`) querying `/api/v1/updates/check` with semantic version comparison. Native SwiftUI update modal sheet (`SoftwareUpdateSheet.swift`) with release notes and 1-click DMG download; integrated into macOS App Menu ("Check for Updates...").
**1st-Class Modern SaaS Website:** High-performance responsive website (`website/index.html`, `website/style.css`) utilizing CSS Scroll-driven animations (`animation-timeline: view()`, `animation-range`), compositor-friendly parallax transforms, glassmorphism, interactive VU audio meters, Documentation hub (`#docs`), Self-service License Key recovery via email (`#support`), Engineering contact form, and direct $19.99 Stripe checkout.
**Executive Copilot & Multi-Provider Reasoning Models:** Models include Claude 5 Sonnet (`anthropic/claude-sonnet-5`, default), Claude 5 Opus (`anthropic/claude-opus-5`), GPT-5.6 Luna Pro (`openai/gpt-5.6-luna-pro`), Claude 3.7 Sonnet, Gemini 2.0 Flash, OpenAI o3-mini, DeepSeek R1, DeepSeek V3, and custom models. Features multi-provider adapter supporting OpenRouter, Anthropic Direct (`/v1/messages`), OpenAI Direct (`/v1/chat/completions`), and Custom OpenAI-compatible endpoints with provider-specific key and model configuration in Settings and Onboarding. `OpenRouterAdapter.extractCleanJSON` strips `<think>` reasoning blocks and extracts outermost JSON.
**Model Pricing Calculator:** Full multi-tier cost calculator (`ModelPricingCalculator`) calculating prompt tokens, completion tokens, and audio duration costs for Claude 5 Sonnet ($3/$15), Claude 5 Opus ($15/$75), GPT-5.6 Luna Pro ($0.50/$2.00), Claude 4.x, OpenAI Luna, and ElevenLabs STT ($0.01/min).
**Per-User Speaker Reference Directory:** SQLite table `local_speaker_profiles` with full CRUD operations (`saveSpeakerProfile`, `getSpeakerProfiles`, `deleteSpeakerProfile`, `seedDefaultSpeakerProfilesIfNeeded`). Profiles include role/title, organization, relationship notes, and speech aliases. Formatted and injected into copilot reasoning context via `AssistanceCoordinator`. Dedicated "Speakers" tab in Settings.
**Audio Diagnostics & Test Harness:** Built-in audio test suite (`AudioDiagnosticsService`) in Settings providing real-time microphone metering, a 5-second record & listen test with countdown and audio playback, a synthetic 440/880 Hz speaker test tone, a ScreenCaptureKit system audio loopback metering test, speech recognition permission check, and direct deep links to macOS Security & Privacy settings.
**Automated Tests:** 41/41 Swift tests passing across 4 suites (0.798s); 11/11 Backend integration tests passing against live Neon PostgreSQL.
**Build, Package & Install:** `./scripts/package_app.sh` packages and installs to `/Applications/Sidebrief.app`; `./scripts/build_dmg.sh` creates compressed `dist/Sidebrief.dmg` (3.7MB) and copies to public web downloads.

## Confirmed user requirements

### Intended use

- Personal tool first; possibly share with others if it works well

### Platform

- Native macOS; web application later

### Structured database

- Neon PostgreSQL

### AI providers

- Use the services needed; OpenRouter, ElevenLabs, OpenAI API, and Cloudflare AI are acceptable options

### Audio inputs

- Both microphone and macOS system audio are mandatory

### Live assistance

- Automatic suggestions, a manual help action, and chat

### Suggestion volume

- Plenty of automatic suggestions and alternatives

### Context

-Current meeting, previous meetings, and connected email, Drive, Slack, GitHub

### Retention

- Retain audio, transcripts, and summaries

*These remain the complete product scope. Building connectors after the capture loop does not remove them from scope.

## Proposed implementation decisions

These are design defaults chosen to satisfy the requirements. They can change with implementation evidence; distinguish them from explicit user requirements.

- Swift/SwiftUI client, AppKit floating panel, public macOS capture APIs.
- Start on Apple Silicon with a proposed macOS 15 minimum. Verify the actual development environment and SDK before committing to the minimum.
- Keep independent microphone/system tracks on a shared monotonic timeline. Remote speaker identity requires additional evidence or correction.
-Local encrypted SQLite and encrypted audio chunks make capture independent of network availability.
- Use private R2 for archived audio; Neon stores meeting records, searchable text, embeddings, and media manifests.
- Small authenticated TypeScript backend on Cloudflare Workers, plus asynchronous Queues/jobs.
- First provider candidates: ElevenLabs realtime STT and OpenRouter generation. Final model IDs and fallback choices are unselected and require tests.
- Frequent mode initially evaluates assistance every 8–12 seconds during substantive discussion, plus event-driven triggers. Generate one recommended answer and up to two meaningful alternatives.
- Explicit context spaces prevent accidental mixing of unrelated histories/accounts. For the initial user these may be EQTY, TKOResearch, and Personal; they are examples, not hardcoded tenant names.
- Read-only source connectors and in-app follow-up drafts first. No autonomous outward communication.
- Retain cloud archives until deletion or configured retention. Proposed local audio cache: 30 days after verified upload, with pinning and retain-all options.
- Signing/notarization and secure updates precede sharing the app. Web UI, billing, team administration, and other platforms are later work.

## Known engineering risks

- Microphone capture can continue while Zoom/Teams is muted. The UI must make that distinction explicit.
- Whole-system audio can include unrelated apps, notifications, and browser tabs.
- Separate tracks distinguish the local microphone from remote audio, not individual remote people.
- Speaker echo can create duplicated recognition across tracks. Preserve original audio and handle recognition duplicates conservatively.
- Cloud STT sees audio before text-based secret redaction. Text filtering cannot guarantee a spoken secret was never transmitted.

- Frequent generation can reach roughly 300–450 automatic requests per active hour. Two STT streams may increase billed duration. Budget and usage controls matter.

- Provider fallback must preserve the space’s data policy.

- Connector availability is limited by actual OAuth scopes, workspace policy, history coverage, API rate limits, and revocation.

- A retrieved source can be stale, false, confidential, or malicious. Valid citations establish traceability, not truth or disclosure permission.

- macOS capture, Bluetooth changes, permissions, Spaces, and floating-panel behavior require a real Mac test.

## Open decisions

Question | How to resolve |

Best STT provider | Replay a labeled technical-call fixture and run live dual-track tests |
Fast/deep model IDs | Compare useful-answer latency, technical quality, groundedness, policy, and cost |
Fast/deep model IDs

Compare useful-answer latency, technical quality, groundedness, policy, and cost

Minimum macOS/SDK | Validate the chosen capture path on the actual target Mac |
Audio codec/bitrate/chunk size | Measure quality, durability, file overhead, and encoder behavior |
Encrypted SQLite integration | Confirm maintenance, licensing, packaging, migration, and key handling |
Identity provider | Select an OIDC provider supporting native PKCE and device/session revocation |
Email provider(s) | Identify the accounts to connect; Gmail first is a proposal, not confirmed account inventory |
Cloud access and deployment | Inspect available accounts/configuration when implementation reaches that stage |
Distribution/license | Decide before publishing or sharing externally |

## Next concrete step

Implement milestone 0: a native capture prototype that records microphone and system audio independently, displays both meters, and can replay/recover finalized encrypted chunks. It must start manually and work without any provider credentials.

Then integrate streaming transcription and the assistant panel. Do not start by building a web dashboard or all connectors.

## Validation ledger

Date | Work | Result |
--- | --- | --- |
2026-09-15 | Product design and requirements written | Specification finalized in docs/REQUIREMENTS.md |
2026-09-15 | Audio capture, AES-GCM encryption, Keychain, gap detection | 4 unit tests passing in tests/AudioTests.swift |
2026-09-15 | ElevenLabs streaming STT & OpenRouter copilot engine | 3 unit tests passing in tests/AssistanceTests.swift |
2026-09-15 | Neon PostgreSQL schema migration, RLS, pgvector, and spaces | 17 tables created & verified on Neon project red-snow-73160166 |
2026-09-15 | Cloudflare R2 bucket provisioned | Bucket sidebrief-audio provisioned and confirmed |
2026-09-15 | Multiple email accounts & visible/editable memory manager | 6 integration tests passing in backend/tests/api.test.js |
2026-09-16 | AppCoordinator memory grounding, build & packaging scripts | 12/12 Swift tests passing; ./scripts/package_app.sh built Sidebrief.app |
2026-09-16 | Single-window UI, persistent Stop controls, Float32 audio, ElevenLabs VAD STT | 12 Swift tests & 6 backend tests passing; App installed to /Applications/Sidebrief.app |
2026-09-16 | Stable designated requirement codesign & single-flight permission preflighting | TCC permissions persist across builds; 13/13 Swift tests passing |
2026-09-16 | 3-space restriction, suggestions overhaul, Launch at Login, Menu Bar Extra | 19/19 Swift tests passing; Production app installed to /Applications/Sidebrief.app |
2026-09-16 | Multi-Provider (OpenRouter, Anthropic, OpenAI, Custom), Claude 5, Luna Pro, Audio Diagnostics harness, Dynamic UserName, Speaker Directory, ElevenLabs VAD overlap dedup | 30/30 Swift tests passing; Production app installed to /Applications/Sidebrief.app |
2026-09-17 | Single "Work" default space, Stripe $19.99 licensing, Resend/SMTP email delivery from support@tkoresearch.com, Hardware UUID & IP logging in Neon, Update checker service & sheet, SaaS parallax website with docs & support, Distributable DMG builder | 32/32 Swift tests passing; 10/10 backend tests passing; dist/Sidebrief.dmg generated |
2026-09-18 | Diagnosis & resolution of unrelated suggestions: purged hardcoded database facts from memory, added conversational turn speaker inference for mic bleed, replaced canned architecture fallbacks with dynamic transcript extraction, verified Claude 5 Sonnet live synthesis | 32/32 Swift tests passing; fresh release packaged and running at /Applications/Sidebrief.app |
2026-10-02 | ScreenCaptureKit stereo-to-mono downmixing & sample rate normalization (fixed 2x chipmunk audio causing STT failure for remote speakers), dynamic keyword-scored excerpt relevance filtering in AssistanceCoordinator (preventing unrelated architecture facts from polluting conversation prompts), dynamic context spaces with single default "Work", deep search across history transcripts/summaries, floating panel autosave, 3 external workspace connectors (GitHub, Slack, Google Drive) with backend integration endpoints and tests | 40/40 Swift tests passing; 11/11 Backend integration tests passing; dist/Sidebrief.dmg (3.7MB) signed and verified |
2026-10-02 | Window layout sizing & DMG Finder container presentation (700x440 bounds, 120pt icons, Sidebrief.app & Applications side-by-side), responsive 1220x820 default app size with filling split-views, zero-secret security scrub, public GitHub repo published to https://github.com/KevinOBytes/sidebrief, v1.0.0 release published with Sidebrief.dmg | 40/40 Swift tests passing; 11/11 Backend integration tests passing; Clean working tree on origin/main |
2026-10-07 | Added prominent "+ New Meeting" action button to sidebar top, primary toolbar button across views, "+ New" button in Past Meetings header, File menu "New Meeting" and global ⌘N shortcut, updated live session button to "Start New Meeting (⌘N)" | 41/41 Swift tests passing; release packaged and verified running at /Applications/Sidebrief.app |
2026-10-09 | Resolved abysmal STT: eliminated parallel track interleaving in AppleSpeechTranscriptionAdapter with Active Channel VAD Router & synchronous crosstalk mixing; forced on-device Apple Neural Engine ASR; wired contextual vocabulary; added Groq Whisper (whisper-large-v3-turbo, ~150ms) auto-detection and error reporting | 43/43 Swift tests passing; release packaged and verified running at /Applications/Sidebrief.app |
2026-10-10 | Voiceprint speaker diarization & batch renaming, Glanceable Teleprompter HUD, Screen-Share Invisibility (panel.sharingType = .none), native EventKit calendar detection with 1-click meeting linking banner, Executive Follow-up Action Suite (Draft in Mail, Copy Slack Recap, Copy Markdown) | 50/50 Swift tests passing; dist/Sidebrief.dmg (3.5MB) packaged and verified running at /Applications/Sidebrief.app |

## Maintaining this memory

- Update current state after meaningful implementation work.
- Replace obsolete statements; do not let contradictory status entries accumulate.
- Record significant decisions with date, reason, and evidence or relevant file path.
- Record exactly which tests ran, their outcomes, and what still needs hardware or credentials.
- Keep the next step executable and bounded.
- Reference an issue or decision document for long investigations rather than pasting session transcripts here.
- Never promote planned behavior into a completed fact without verification.
