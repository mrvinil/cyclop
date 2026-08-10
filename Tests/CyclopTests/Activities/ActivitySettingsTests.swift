import XCTest
@testable import Cyclop

final class ActivitySettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let homeDirectory = URL(fileURLWithPath: "/Users/test")

    override func setUp() {
        super.setUp()
        suiteName = "ActivitySettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultsMatchSpecification() {
        let settings = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.mediaEnabled)
        XCTAssertTrue(settings.meetingsEnabled)
        XCTAssertTrue(settings.timersEnabled)
        XCTAssertTrue(settings.downloadsEnabled)
        XCTAssertEqual(settings.meetingLeadMinutes, 15)
        XCTAssertTrue(settings.timerSoundEnabled)
        XCTAssertEqual(settings.mediaAnimationMode, .slow)
        XCTAssertEqual(settings.downloadsFolder.path, "/Users/test/Downloads")
    }

    @MainActor
    func testChangesArePersistedAndRestored() {
        let settings = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)
        let downloadsFolder = URL(fileURLWithPath: "/Users/test/Projects/Downloads")

        settings.isEnabled = false
        settings.mediaEnabled = false
        settings.meetingsEnabled = false
        settings.timersEnabled = false
        settings.downloadsEnabled = false
        settings.meetingLeadMinutes = 30
        settings.timerSoundEnabled = false
        settings.mediaAnimationMode = .fluid
        settings.downloadsFolder = downloadsFolder

        let restored = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(restored.mediaEnabled)
        XCTAssertFalse(restored.meetingsEnabled)
        XCTAssertFalse(restored.timersEnabled)
        XCTAssertFalse(restored.downloadsEnabled)
        XCTAssertEqual(restored.meetingLeadMinutes, 30)
        XCTAssertFalse(restored.timerSoundEnabled)
        XCTAssertEqual(restored.mediaAnimationMode, .fluid)
        XCTAssertEqual(restored.downloadsFolder, downloadsFolder)
    }

    @MainActor
    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set(7, forKey: "activities.meetingLeadMinutes")
        defaults.set("unsupported", forKey: "activities.mediaAnimationMode")

        let settings = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)

        XCTAssertEqual(settings.meetingLeadMinutes, 15)
        XCTAssertEqual(settings.mediaAnimationMode, .slow)
    }
}
