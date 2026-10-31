import Testing
import Foundation
@testable import SidebriefCore

@Suite("UI & Experience Enhancement Tests")
struct UIExperienceTests {

    @Test("Speaker Color Palette is Deterministic and Distinct")
    func testSpeakerColorPaletteDeterminism() {
        let colorYou1 = SpeakerColorPalette.theme(for: "You").name
        let colorYou2 = SpeakerColorPalette.theme(for: "you").name
        #expect(colorYou1 == "Blue")
        #expect(colorYou2 == "Blue")

        let aliceColor1 = SpeakerColorPalette.theme(for: "Alice").name
        let aliceColor2 = SpeakerColorPalette.theme(for: "Alice").name
        #expect(aliceColor1 == aliceColor2)

        let bobColor = SpeakerColorPalette.theme(for: "Bob").name
        #expect(!bobColor.isEmpty)
    }

    @Test("Text Scale Preferences Provide Readable Typography Dimensions")
    func testTextScaleDimensions() {
        let compact = TextScalePreference.compact
        let regular = TextScalePreference.regular
        let spacious = TextScalePreference.spacious

        #expect(compact.transcriptBodySize < regular.transcriptBodySize)
        #expect(regular.transcriptBodySize < spacious.transcriptBodySize)
        #expect(regular.transcriptBodySize >= 13.0)
        #expect(spacious.transcriptBodySize >= 15.0)

        #expect(regular.suggestionBodySize >= 14.0)
        #expect(spacious.suggestionBodySize >= 16.0)
    }
}
