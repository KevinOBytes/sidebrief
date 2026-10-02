import Testing
import Foundation
@testable import SidebriefCore

@Suite("Storage & Sync Tests")
struct StorageTests {

    @Test("Local Database Meeting CRUD")
    func testLocalDatabaseMeetingCRUD() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let meeting = Meeting(
            id: "m-\(UUID().uuidString)",
            spaceId: "space-eqty",
            title: "Q3 Product Architecture",
            state: .scheduled,
            agenda: "Review roadmap and capture pipeline",
            sensitivity: "confidential",
            version: 1
        )

        store.saveMeeting(meeting)

        let fetched = store.getMeeting(id: meeting.id)
        #expect(fetched != nil)
        #expect(fetched?.id == meeting.id)
        #expect(fetched?.spaceId == "space-eqty")
        #expect(fetched?.title == "Q3 Product Architecture")
        #expect(fetched?.state == .scheduled)
        #expect(fetched?.version == 1)

        // Update meeting state
        var updated = meeting
        updated.state = .recording
        updated.version = 2
        store.saveMeeting(updated)

        let fetchedUpdated = store.getMeeting(id: meeting.id)
        #expect(fetchedUpdated?.state == .recording)
        #expect(fetchedUpdated?.version == 2)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Meeting Listing, Filtering, and Deletion")
    func testMeetingsListingFilteringAndDeletion() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_meetings.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let m1 = Meeting(
            id: "m-1",
            spaceId: "space-eqty",
            title: "Q3 Product Architecture",
            state: .completed,
            agenda: "Review roadmap and capture pipeline"
        )
        let m2 = Meeting(
            id: "m-2",
            spaceId: "space-eqty",
            title: "Executive Compensation Review",
            state: .completed,
            agenda: "Budget allocations"
        )
        let m3 = Meeting(
            id: "m-3",
            spaceId: "space-personal",
            title: "Personal Mentorship Catchup",
            state: .completed,
            agenda: "Career goals"
        )

        store.saveMeeting(m1)
        store.saveMeeting(m2)
        store.saveMeeting(m3)

        // All meetings
        let all = store.getMeetings()
        #expect(all.count == 3)

        // Filter by space
        let eqtyMeetings = store.getMeetings(spaceId: "space-eqty")
        #expect(eqtyMeetings.count == 2)
        #expect(eqtyMeetings.contains(where: { $0.id == "m-1" }))
        #expect(eqtyMeetings.contains(where: { $0.id == "m-2" }))

        // Filter by search query
        let searchArchitecture = store.getMeetings(query: "Architecture")
        #expect(searchArchitecture.count == 1)
        #expect(searchArchitecture[0].id == "m-1")

        let searchBudget = store.getMeetings(query: "budget")
        #expect(searchBudget.count == 1)
        #expect(searchBudget[0].id == "m-2")

        // Delete meeting
        store.deleteMeeting(id: "m-1", spaceId: "space-eqty")
        let afterDelete = store.getMeetings()
        #expect(afterDelete.count == 2)
        #expect(!afterDelete.contains(where: { $0.id == "m-1" }))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Transcript Segments and Summary Persistence")
    func testTranscriptSegmentsAndSummaryPersistence() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_transcript_summary.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let meetingId = "m-ts-1"
        let parentMeeting = Meeting(id: meetingId, spaceId: "space-eqty", title: "Architecture Session", state: .completed)
        store.saveMeeting(parentMeeting)

        let segments = [
            TranscriptSegment(
                id: "seg-1",
                meetingId: meetingId,
                trackId: "mic",
                providerSegmentId: "seg-1",
                speakerLabel: "You",
                text: "Welcome everyone to our architecture session.",
                startOffsetMs: 0,
                endOffsetMs: 2500
            ),
            TranscriptSegment(
                id: "seg-2",
                meetingId: meetingId,
                trackId: "sys",
                providerSegmentId: "seg-2",
                speakerLabel: "Alice",
                text: "Thanks Kevin, we are ready to discuss Neon PostgreSQL and R2 storage.",
                startOffsetMs: 2600,
                endOffsetMs: 6000
            )
        ]

        store.saveTranscriptSegments(segments)

        let fetchedSegments = store.getTranscriptSegments(meetingId: meetingId)
        #expect(fetchedSegments.count == 2)
        #expect(fetchedSegments[0].speakerLabel == "You")
        #expect(fetchedSegments[1].speakerLabel == "Alice")
        #expect(fetchedSegments[1].text.contains("Neon PostgreSQL"))

        // Save and fetch summary
        let summary = MeetingSummary(
            id: "sum-1",
            meetingId: meetingId,
            version: 1,
            overview: "Discussed local audio capture and Neon persistence.",
            keyPoints: ["Capture mic and system audio separately", "Durable SQLite local storage"],
            decisions: [
                DecisionItem(title: "Use Neon for sync", rationale: "Built-in pgvector and RLS support", status: "confirmed")
            ],
            actionItems: [
                ActionItem(task: "Finalize SQLite queries", assignee: "Kevin", dueDate: "Today", status: "completed")
            ],
            unresolvedQuestions: ["Should we add cloud R2 sync retry limits?"],
            followUpEmailDraft: "Hi Team,\nGreat meeting today. Action items attached."
        )

        store.saveSummary(summary)

        let fetchedSummary = store.getSummary(meetingId: meetingId)
        #expect(fetchedSummary != nil)
        #expect(fetchedSummary?.meetingId == meetingId)
        #expect(fetchedSummary?.overview == "Discussed local audio capture and Neon persistence.")
        #expect(fetchedSummary?.keyPoints.count == 2)
        #expect(fetchedSummary?.decisions.count == 1)
        #expect(fetchedSummary?.decisions[0].title == "Use Neon for sync")
        #expect(fetchedSummary?.actionItems.count == 1)
        #expect(fetchedSummary?.actionItems[0].assignee == "Kevin")
        #expect(fetchedSummary?.followUpEmailDraft?.contains("Action items attached") == true)

        // Test Deep Search across transcript segments and summary content
        let transcriptMatches = store.getMeetings(query: "R2 storage")
        #expect(transcriptMatches.count == 1)
        #expect(transcriptMatches[0].id == meetingId)

        let summaryMatches = store.getMeetings(query: "Finalize SQLite queries")
        #expect(summaryMatches.count == 1)
        #expect(summaryMatches[0].id == meetingId)

        let unmatched = store.getMeetings(query: "CompletelyUnrelatedTermXYZ")
        #expect(unmatched.isEmpty)

        // Delete meeting cascading check
        store.deleteMeeting(id: meetingId, spaceId: "space-eqty")
        #expect(store.getTranscriptSegments(meetingId: meetingId).isEmpty)
        #expect(store.getSummary(meetingId: meetingId) == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Durable Outbox Queue and Drain")
    func testOutboxDrain() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_outbox.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let meeting = Meeting(
            id: "m-outbox-1",
            spaceId: "space-tkoresearch",
            title: "Autonomous Agent Architecture",
            state: .completed
        )

        store.saveMeeting(meeting)

        let pending = store.getPendingOutboxEntries()
        #expect(pending.count >= 1)
        #expect(pending.contains(where: { $0.entityId == "m-outbox-1" }))

        let entryIds = pending.map { $0.id }
        store.markOutboxSuccess(ids: entryIds)

        let afterDrain = store.getPendingOutboxEntries()
        #expect(afterDrain.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Memory Facts Storage, Retrieval, Pinning, and Deletion")
    func testMemoryFactsCRUD() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_memory.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let fact1 = MemoryFact(
            id: "mem-1",
            spaceId: "space-eqty",
            category: "Architecture",
            key: "Database",
            value: "Neon PostgreSQL",
            source: "bootstrapped",
            isPinned: true
        )
        let fact2 = MemoryFact(
            id: "mem-2",
            spaceId: "space-eqty",
            category: "Architecture",
            key: "Storage",
            value: "Cloudflare R2",
            source: "manual",
            isPinned: false
        )
        let personalFact = MemoryFact(
            id: "mem-3",
            spaceId: "space-personal",
            category: "Health",
            key: "Allergies",
            value: "None",
            source: "manual",
            isPinned: true
        )

        store.saveMemoryFact(fact1)
        store.saveMemoryFact(fact2)
        store.saveMemoryFact(personalFact)

        // Verify retrieval & space isolation
        let eqtyFacts = store.getMemoryFacts(for: "space-eqty")
        #expect(eqtyFacts.count == 2)
        #expect(eqtyFacts[0].id == "mem-1") // pinned first
        #expect(eqtyFacts[1].id == "mem-2")

        let personalFacts = store.getMemoryFacts(for: "space-personal")
        #expect(personalFacts.count == 1)
        #expect(personalFacts[0].key == "Allergies")

        // Edit fact
        var updatedFact2 = fact2
        updatedFact2.value = "Cloudflare R2 Encrypted Chunks"
        updatedFact2.isPinned = true
        store.saveMemoryFact(updatedFact2)

        let reloaded = store.getMemoryFacts(for: "space-eqty")
        #expect(reloaded.first(where: { $0.id == "mem-2" })?.value == "Cloudflare R2 Encrypted Chunks")
        #expect(reloaded.first(where: { $0.id == "mem-2" })?.isPinned == true)

        // Delete fact
        store.deleteMemoryFact(id: "mem-1", spaceId: "space-eqty")
        let afterDelete = store.getMemoryFacts(for: "space-eqty")
        #expect(afterDelete.count == 1)
        #expect(afterDelete[0].id == "mem-2")

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Multiple Email Accounts Storage, Retrieval, and Space Isolation")
    func testMultiEmailAccountsCRUD() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_email.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        let workAccount = EmailAccountConfig(
            id: "email-work",
            spaceId: "space-eqty",
            accountName: "Work Google Workspace",
            emailAddress: "kevin@eqty.internal",
            imapHost: "imap.gmail.com",
            imapPort: 993,
            useTls: true,
            authType: "oauth2",
            syncFolder: "INBOX",
            isEnabled: true
        )

        let advisoryAccount = EmailAccountConfig(
            id: "email-advisory",
            spaceId: "space-eqty",
            accountName: "TKO Advisory Mail",
            emailAddress: "kevin@tko.internal",
            imapHost: "imap.fastmail.com",
            imapPort: 993,
            useTls: true,
            authType: "app_password",
            syncFolder: "INBOX",
            isEnabled: true
        )

        let personalAccount = EmailAccountConfig(
            id: "email-personal",
            spaceId: "space-personal",
            accountName: "Personal iCloud",
            emailAddress: "kevin@icloud.com",
            imapHost: "imap.mail.me.com",
            imapPort: 993,
            useTls: true,
            authType: "app_password",
            syncFolder: "INBOX",
            isEnabled: true
        )

        store.saveEmailAccount(workAccount)
        store.saveEmailAccount(advisoryAccount)
        store.saveEmailAccount(personalAccount)

        // Test retrieval & space isolation
        let eqtyAccounts = store.getEmailAccounts(for: "space-eqty")
        #expect(eqtyAccounts.count == 2)
        #expect(eqtyAccounts.contains(where: { $0.emailAddress == "kevin@eqty.internal" }))
        #expect(eqtyAccounts.contains(where: { $0.emailAddress == "kevin@tko.internal" }))
        #expect(!eqtyAccounts.contains(where: { $0.emailAddress == "kevin@icloud.com" }))

        let personalAccounts = store.getEmailAccounts(for: "space-personal")
        #expect(personalAccounts.count == 1)
        #expect(personalAccounts[0].emailAddress == "kevin@icloud.com")

        // Delete account
        store.deleteEmailAccount(id: "email-work")
        let remainingEqty = store.getEmailAccounts(for: "space-eqty")
        #expect(remainingEqty.count == 1)
        #expect(remainingEqty[0].id == "email-advisory")

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Context Spaces Storage, Customization, and Single Work Space Setup")
    func testContextSpacesStorageRetrievalAndRestriction() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_spaces.sqlite")

        let store = LocalDatabaseStore(databaseURL: dbURL)

        for space in ContextSpace.defaultSpaces {
            store.saveContextSpace(space)
        }

        let fetched = store.getContextSpaces()
        #expect(fetched.count == 1)
        #expect(fetched[0].id == "space-work")
        #expect(fetched[0].name == "Work")

        // Update customization for Work
        var work = fetched[0]
        work.name = "Work & Engineering"
        work.retentionDays = 730
        work.customPrompt = "Focus strictly on audio pipelines and distributed DBs."
        store.saveContextSpace(work)

        let updated = store.getContextSpace(id: "space-work")
        #expect(updated != nil)
        #expect(updated?.name == "Work & Engineering")
        #expect(updated?.retentionDays == 730)
        #expect(updated?.customPrompt == "Focus strictly on audio pipelines and distributed DBs.")

        // Verify custom space can be saved and retrieved
        let customSpace = ContextSpace(id: "space-venture", name: "Venture Advisory", description: "Venture notes")
        store.saveContextSpace(customSpace)
        let afterCustom = store.getContextSpaces()
        #expect(afterCustom.contains(where: { $0.id == "space-venture" }))

        // Verify invalid empty space ID is rejected
        let invalidSpace = ContextSpace(id: " ", name: "Invalid", description: "Empty ID")
        store.saveContextSpace(invalidSpace)
        let afterInvalid = store.getContextSpaces()
        #expect(!afterInvalid.contains(where: { $0.id == " " }))

        // Verify custom space deletion
        store.deleteContextSpace(id: "space-venture")
        let afterDelete = store.getContextSpaces()
        #expect(!afterDelete.contains(where: { $0.id == "space-venture" }))

        // Verify primary work space cannot be deleted
        store.deleteContextSpace(id: "space-work")
        let afterProtected = store.getContextSpaces()
        #expect(afterProtected.contains(where: { $0.id == "space-work" }))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("License Manager Activation, Hardware UUID, and Key Masking")
    @MainActor
    func testLicenseManagerActivationAndMasking() async {
        let manager = LicenseManager.shared
        let testKey = "SB-1234-ABCD-5678-EF90"
        let testEmail = "testuser@example.com"

        // Verify hardware UUID is generated and non-empty
        let hwid = LicenseManager.getHardwareUUID()
        #expect(!hwid.isEmpty)

        // Activate with syntax key
        let activated = await manager.activate(key: testKey, email: testEmail)
        #expect(activated == true)
        #expect(manager.isLicensed == true)
        #expect(manager.licenseKey == testKey)
        #expect(manager.maskedKey.hasPrefix("SB-"))
        #expect(manager.maskedKey.hasSuffix("EF90"))

        // Deep link handler
        let deepLinkUrl = URL(string: "sidebrief://activate?key=SB-5555-6666-7777-8888")!
        let handled = manager.handleActivationUrl(deepLinkUrl)
        #expect(handled == true)

        // Cleanup
        manager.deactivate()
        #expect(manager.isLicensed == false)
    }

    @Test("Update Checker Semantic Version Comparison")
    func testUpdateCheckerSemanticVersionComparison() {
        #expect(UpdateCheckerService.isVersion("1.0.1", greaterThan: "1.0.0") == true)
        #expect(UpdateCheckerService.isVersion("1.1.0", greaterThan: "1.0.9") == true)
        #expect(UpdateCheckerService.isVersion("2.0.0", greaterThan: "1.99.99") == true)
        #expect(UpdateCheckerService.isVersion("1.0.0", greaterThan: "1.0.1") == false)
        #expect(UpdateCheckerService.isVersion("1.0.0", greaterThan: "1.0.0") == false)
        #expect(UpdateCheckerService.isVersion("v1.2.3", greaterThan: "1.2.2") == true)
    }
}

