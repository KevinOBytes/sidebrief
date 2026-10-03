# Show HN Submission Copy

## Submission Details

- **Title:** `Show HN: Sidebrief – Native macOS meeting copilot with dual capture and local encryption`
- **URL (optional, or submit as Text):** `https://github.com/KevinOBytes/sidebrief`
  *(Note: Text submissions allow you to provide the explanatory post below directly on HN. Text submissions usually perform better for Show HNs because they explain the architecture, motivation, and installation commands).*

---

## Post Body (Markdown)

Hi HN,

I built Sidebrief (https://github.com/KevinOBytes/sidebrief) because I wanted a reliable, real-time meeting copilot on macOS without the privacy and UX compromises of existing tools.

Most meeting assistants today fall into two categories:
1. **Third-party bots:** They require inviting a bot (e.g. `Otter / Fireflies / Read.ai has joined the meeting`) that announces itself, records everyone to a vendor’s cloud, and annoys clients or coworkers.
2. **Electron web wrappers:** High CPU and memory usage right when your Mac is already working hard on video conferencing, combined with $20–$35/month recurring subscriptions.

Sidebrief is built in Swift 6, SwiftUI, and AppKit specifically for macOS.

### Key Architecture & Invariants

- **Dual-Stream System & Mic Capture:** Uses Apple's ScreenCaptureKit alongside AVFoundation to capture both physical microphone input and macOS system audio as independent, synchronized tracks on a monotonic timeline. No bot joins your Zoom, Teams, or Google Meet calls. Remote speaker audio is downmixed to 16kHz mono in real-time.
- **Local Authenticated Encryption:** Temporary and finalized audio chunks are authenticated and encrypted using CryptoKit AES-GCM with keys managed in the macOS Keychain. Raw unencrypted audio is never written to disk.
- **Multi-STT Options (Including On-Device):** Supports macOS native `Speech.framework` (Apple Speech) for 100% on-device, zero-cost, zero-API-key transcription. Also includes streaming adapters for ElevenLabs Scribe v2 (low-latency WebSocket) and Whisper.
- **Executive Copilot with Strategic Alternatives:** Runs an 8–12 second cadence during substantive speech, with immediate event-driven triggers when a direct question or decision point is detected. Rather than generating a single wall of text, it outputs a concise recommended answer and up to two distinct strategic alternatives (e.g. conservative approach vs. direct pushback).
- **Offline-First & Neon Sync:** Operates completely offline with an encrypted local SQLite store. When connected, structured metadata, summaries, and transcripts sync to Neon PostgreSQL with pgvector for semantic retrieval across past meetings, email, Slack, and GitHub.
- **Focus Invariant:** Floating assistant cards never steal keyboard focus, resize unexpectedly, or rewrite text while you are actively reading or selecting it.

### Getting Started

You can install it directly via Homebrew:

```bash
brew install KevinOBytes/sidebrief/sidebrief
```

Or tap the repository:

```bash
brew tap KevinOBytes/sidebrief
brew install --cask sidebrief
```

You can also download the signed DMG directly from GitHub Releases:
https://github.com/KevinOBytes/sidebrief/releases/tag/v1.0.0

The source code and architecture documentation are available at:
https://github.com/KevinOBytes/sidebrief

### Questions / Feedback

I'd love to hear your thoughts, especially from folks working with macOS audio pipelines:
1. What suggestion frequency or UI placement feels least intrusive during live calls?
2. Are there specific edge cases you've encountered with ScreenCaptureKit audio loopback on macOS Sonoma/Sequoia?

Happy to answer questions about the capture pipeline, local encryption model, or prompt debounce heuristics.
