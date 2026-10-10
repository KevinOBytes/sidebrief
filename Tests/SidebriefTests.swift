import Testing
import Foundation
@testable import SidebriefCore

@Suite("Sidebrief Baseline Tests")
struct SidebriefBaselineTests {
    @Test("Version check")
    func testVersion() {
        #expect(SidebriefVersion.appName == "Sidebrief")
        #expect(SidebriefVersion.version == "1.0.0")
    }

    @Test("Calendar Meeting Event Time Calculations and Status Badge")
    func testCalendarMeetingEvent() {
        let now = Date()
        let inTenMins = Calendar.current.date(byAdding: .minute, value: 10, to: now)!
        let inFortyMins = Calendar.current.date(byAdding: .minute, value: 40, to: now)!

        let upcomingEvent = CalendarMeetingEvent(
            id: "event-1",
            title: "Q4 Roadmap Review",
            startDate: inTenMins,
            endDate: inFortyMins,
            attendees: ["Dave", "Sarah", "Alex"],
            locationOrURL: "https://zoom.us/j/123456789",
            notes: "Please bring metrics"
        )

        #expect(!upcomingEvent.isHappeningNow)
        #expect(upcomingEvent.minutesUntilStart >= 9 && upcomingEvent.minutesUntilStart <= 11)
        #expect(upcomingEvent.statusBadge.contains("10m") || upcomingEvent.statusBadge.contains("9m"))
        #expect(!upcomingEvent.formattedTimeRange.isEmpty)
        #expect(upcomingEvent.attendees.count == 3)

        // Event happening right now
        let thirtyMinsAgo = Calendar.current.date(byAdding: .minute, value: -30, to: now)!
        let activeEvent = CalendarMeetingEvent(
            id: "event-2",
            title: "Emergency Standup",
            startDate: thirtyMinsAgo,
            endDate: inTenMins,
            attendees: ["Dave"]
        )
        #expect(activeEvent.isHappeningNow)
        #expect(activeEvent.statusBadge == "Happening Now")
    }

    @Test("Meeting Summary Executive Structure and Action Item Mapping")
    func testMeetingSummaryExecutiveStructure() {
        let meetingId = "m-exec-\(UUID().uuidString)"
        let action1 = ActionItem(task: "Finalize revised SOW pricing", assignee: "Dave", dueDate: "Thursday")
        let action2 = ActionItem(task: "Send SOC 2 Type II report", assignee: "Sarah", dueDate: "Friday")

        let dec1 = DecisionItem(title: "Approved 15% discount cap", rationale: "Standard volume tier")
        let dec2 = DecisionItem(title: "Agreed on Net 30 payment terms", rationale: "Vendor procurement standard")

        let summary = MeetingSummary(
            id: "sum-1",
            meetingId: meetingId,
            version: 1,
            overview: "Agreed to proceed with Enterprise pilot subject to security sign-off.",
            keyPoints: ["Discussed 15% discount structure", "Reviewed SOC 2 compliance"],
            decisions: [dec1, dec2],
            actionItems: [action1, action2],
            unresolvedQuestions: ["Who is the secondary billing contact?"],
            followUpEmailDraft: "Hi Team,\n\nThanks for meeting today. We agreed on...",
            createdAt: Date()
        )

        #expect(summary.actionItems.count == 2)
        #expect(summary.decisions.count == 2)
        #expect(summary.actionItems.first?.assignee == "Dave")
        #expect(summary.actionItems.first?.task == "Finalize revised SOW pricing")
        #expect(summary.followUpEmailDraft != nil)
    }
}
