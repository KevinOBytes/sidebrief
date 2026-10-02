# Sidebrief — Technology Stack & Tools

## Native Client (macOS)
- **Language**: Swift 6 (Swift 6.3.3 / macOS 26 SDK)
- **UI Frameworks**: SwiftUI (Main window, Inspector, Live Transcript, Settings), AppKit (`NSPanel` HUD for non-activating floating assistant panel, `NSStatusBar` menu-bar integration, global event monitors)
- **Capture Engines**:
  - `ScreenCaptureKit` (`SCStream`, `SCStreamConfiguration`, `SCContentFilter`) for macOS system audio (both whole-system and per-app capture)
  - `AVFoundation` (`AVCaptureSession`, `AVAudioEngine`, `AVCaptureDevice`) for microphone input capture with device selection
- **Audio Processing**:
  - `AVAudioConverter` / CoreAudio for realtime format conversion, sample rate conversion (e.g. 48kHz archival to 16kHz PCM mono for STT), and RMS/peak power metering
- **Cryptography & Local Security**:
  - Apple `CryptoKit` (`AES.GCM` / `ChaChaPoly`, `SHA256`) for authenticated chunk-level audio encryption
  - macOS Keychain Services for master encryption keys and session tokens
- **Local Database**:
  - SQLite3 (`libsqlite3`) via Swift wrapper for local meeting journal, transcript ledger, search cache, and durable sync outbox

## Cloud & Backend Services
- **Cloud Database**: Neon PostgreSQL (PostgreSQL 18+)
  - Row-Level Security (RLS) policies by context space and user ID
  - `pgvector` for dense semantic vector embeddings (HNSW index)
  - PostgreSQL Full-Text Search (`tsvector`, `tsquery`, GIN index) for lexical retrieval
- **Backend API**:
  - TypeScript / Node.js & Cloudflare Workers compatible Hono API
  - Ephemeral token brokerage for realtime STT sessions
  - Idempotent sync endpoints with tombstone deletion propagation
  - Hybrid lexical + vector search retrieval endpoint
- **Object Storage**:
  - Cloudflare R2 (S3-compatible) for encrypted audio chunk archiving with signed upload/download grants
- **AI & ML Providers**:
  - **Speech-to-Text (STT)**: ElevenLabs Scribe realtime WebSocket API (`wss://api.elevenlabs.io/...`), with provisional and committed transcript events
  - **Live Copilot & Reasoning**: OpenRouter API (`https://openrouter.ai/api/v1/chat/completions`) for fast response generation and deep technical analysis
  - **Summaries & Memory**: Cloud LLMs via OpenRouter / OpenAI
- **Connected Context Sources**:
  - Email (IMAP / Gmail API)
  - Google Drive (Google Drive API v3)
  - Slack (Slack Web API)
  - GitHub (GitHub REST / GraphQL API v3/v4)

## Tooling & Automation
- `swift build`, `swift test`: Apple Swift Package Manager
- `xcodebuild`: Xcode native build and app packaging
- `npm` / `pnpm`: Backend package management and testing
- Custom test harnesses & synthetic audio fixtures
