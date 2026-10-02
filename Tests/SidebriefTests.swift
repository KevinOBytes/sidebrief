import Testing
@testable import SidebriefCore

@Suite("Sidebrief Baseline Tests")
struct SidebriefBaselineTests {
    @Test("Version check")
    func testVersion() {
        #expect(SidebriefVersion.appName == "Sidebrief")
        #expect(SidebriefVersion.version == "1.0.0")
    }
}
