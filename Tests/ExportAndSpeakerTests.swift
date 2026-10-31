import Testing
import Foundation
@testable import SidebriefCore

@Suite("Export & Speaker Management Tests")
struct ExportAndSpeakerTests {

    @Test("Plain Text Transcript Export Format")
    func testPlainTextExport() {
        let exportService = MeetingExportService.shared
        let meeting = Meeting(
            spaceId: "space-work",
            title: "Q4 Architecture Planning",
            agenda: "Review roadmap and audio capture",
            sensitivity: "confidential"
        )

        let segments = [
            TranscriptSegment(
                meetingId: meeting.id,
                trackId: "track-mic",
                speakerLabel: "You",
                text: "Let's align on the new export format and speaker naming.",
                startOffsetMs: 0,
                endOffsetMs: 2400,
                isProvisional: false
            ),
            TranscriptSegment(
                meetingId: meeting.id,
                trackId: "track-sys",
                speakerLabel: "Sarah (Lead Engineer)",
                text: "We should support native PDF, plain text, and JSON.",
                startOffsetMs: 2500,
                endOffsetMs: 5100,
                isProvisional: false
            )
        ]

        let summary = MeetingSummary(
            meetingId: meeting.id,
            overview: "Discussed export capabilities and speaker identification.",
            keyPoints: ["Added PDF vector generation", "Enabled platform-wide speaker naming"],
            decisions: [
                DecisionItem(title: "Multi-Format Export", rationale: "Enables instant PDF/TXT/JSON downloading")
            ],
            actionItems: [
                ActionItem(task: "Deploy update to team", assignee: "Kevin", dueDate: "Friday")
            ]
        )

        let plainText = exportService.generatePlainText(meeting: meeting, segments: segments, summary: summary)

        #expect(plainText.contains("SIDEBRIEF MEETING JOURNAL"))
        #expect(plainText.contains("Title:    Q4 Architecture Planning"))
        #expect(plainText.contains("Speakers: Sarah (Lead Engineer), You"))
        #expect(plainText.contains("--- EXECUTIVE SUMMARY ---"))
        #expect(plainText.contains("Discussed export capabilities"))
        #expect(plainText.contains("--- KEY DISCUSSION POINTS ---"))
        #expect(plainText.contains("Added PDF vector generation"))
        #expect(plainText.contains("--- CONFIRMED DECISIONS ---"))
        #expect(plainText.contains("Multi-Format Export"))
        #expect(plainText.contains("--- ACTION ITEMS ---"))
        #expect(plainText.contains("[Kevin] Deploy update to team"))
        #expect(plainText.contains("--- TRANSCRIPT ---"))
        #expect(plainText.contains("[00:00] You: Let's align on the new export format"))
        #expect(plainText.contains("[00:02] Sarah (Lead Engineer): We should support native PDF"))
    }

    @Test("Structured JSON Transcript Export Format")
    func testJSONExport() throws {
        let exportService = MeetingExportService.shared
        let meeting = Meeting(
            spaceId: "space-work",
            title: "Sprint Retrospective",
            agenda: "",
            sensitivity: "internal"
        )

        let segments = [
            TranscriptSegment(
                meetingId: meeting.id,
                trackId: "track-mic",
                speakerLabel: "You",
                text: "Session concluded cleanly.",
                startOffsetMs: 1200,
                endOffsetMs: 3400,
                isProvisional: false
            )
        ]

        let summary = MeetingSummary(
            meetingId: meeting.id,
            overview: "Sprint completed with 100% velocity.",
            keyPoints: ["All targets hit"],
            decisions: [],
            actionItems: []
        )

        guard let jsonData = exportService.generateJSONData(meeting: meeting, segments: segments, summary: summary) else {
            #expect(Bool(false), "JSON data generation returned nil")
            return
        }

        #expect(!jsonData.isEmpty)

        // Validate JSON deserialization
        let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        #expect(obj != nil)
        #expect(obj?["schemaVersion"] as? String == "1.0")
        #expect(obj?["generator"] as? String == "Sidebrief macOS")

        let meetingObj = obj?["meeting"] as? [String: Any]
        #expect(meetingObj?["id"] as? String == meeting.id)
        #expect(meetingObj?["title"] as? String == "Sprint Retrospective")

        let segmentsArray = obj?["transcript"] as? [[String: Any]]
        #expect(segmentsArray?.count == 1)
        #expect(segmentsArray?.first?["speaker"] as? String == "You")
        #expect(segmentsArray?.first?["text"] as? String == "Session concluded cleanly.")

        let participants = meetingObj?["participants"] as? [String]
        #expect(participants?.contains("You") == true)
    }

    @Test("Native Vector PDF Generation")
    func testPDFExport() {
        let exportService = MeetingExportService.shared
        let meeting = Meeting(
            spaceId: "space-work",
            title: "Board of Directors Briefing",
            agenda: "Quarterly performance review",
            sensitivity: "restricted"
        )

        let segments = [
            TranscriptSegment(
                meetingId: meeting.id,
                trackId: "track-mic",
                speakerLabel: "You",
                text: "Welcome everyone to the quarterly board meeting.",
                startOffsetMs: 0,
                endOffsetMs: 2500,
                isProvisional: false
            ),
            TranscriptSegment(
                meetingId: meeting.id,
                trackId: "track-sys",
                speakerLabel: "Evelyn Reed (CFO)",
                text: "Revenue surpassed expectations by fourteen percent.",
                startOffsetMs: 3000,
                endOffsetMs: 6500,
                isProvisional: false
            )
        ]

        let summary = MeetingSummary(
            meetingId: meeting.id,
            overview: "Revenue outpaced forecasts with 14% growth.",
            keyPoints: ["Exceeded Q3 margin goals", "Approved expansion budget"],
            decisions: [
                DecisionItem(title: "Approve Expansion", rationale: "Capital is allocated")
            ],
            actionItems: [
                ActionItem(task: "File regulatory disclosure", assignee: "Legal", dueDate: "Monday")
            ]
        )

        let pdfData = exportService.generatePDFData(meeting: meeting, segments: segments, summary: summary)
        #expect(pdfData != nil)
        guard let data = pdfData else { return }

        #expect(data.count > 100)
        // Check standard PDF magic header: %PDF
        let header = String(data: data.prefix(4), encoding: .ascii)
        #expect(header == "%PDF")
    }

    @Test("Add Named Speaker to Meeting and Enrolls in Directory")
    func testAddNamedSpeaker() {
        let diarizationService = SpeakerDiarizationService.shared
        let meetingId = "test-meeting-\(UUID().uuidString)"
        let spaceId = "space-test-\(UUID().uuidString)"

        let speakerName = "Dr. Elizabeth Vance"

        // Add speaker
        let speaker = diarizationService.addNamedSpeaker(
            meetingId: meetingId,
            spaceId: spaceId,
            name: speakerName,
            genderEstimate: "Female",
            roleOrTitle: "Chief Medical Officer",
            saveToDirectory: true
        )

        #expect(speaker.assignedLabel == speakerName)
        #expect(speaker.genderEstimate == "Female")

        // Check it appears in session clusters
        let sessionSpeakers = diarizationService.getSessionSpeakers(meetingId: meetingId)
        #expect(sessionSpeakers.contains(where: { $0.assignedLabel == speakerName }))

        // Check it was enrolled in LocalDatabaseStore
        let profiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
        #expect(profiles.contains(where: { $0.name == speakerName }))

        // Idempotency: adding again shouldn't duplicate
        let secondAdd = diarizationService.addNamedSpeaker(
            meetingId: meetingId,
            spaceId: spaceId,
            name: speakerName,
            genderEstimate: "Female",
            saveToDirectory: true
        )
        #expect(secondAdd.assignedLabel == speakerName)

        let updatedSpeakers = diarizationService.getSessionSpeakers(meetingId: meetingId)
        let count = updatedSpeakers.filter { $0.assignedLabel == speakerName }.count
        #expect(count == 1)

        // Clean up
        diarizationService.endMeeting(meetingId: meetingId)
    }
}
