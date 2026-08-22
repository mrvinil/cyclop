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
        XCTAssertEqual(settings.mediaAnimationMode, .universal)
        XCTAssertEqual(settings.downloadsFolder.path, "/Users/test/Downloads")
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
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
        settings.mediaAnimationMode = .rockHits
        settings.downloadsFolder = downloadsFolder

        XCTAssertEqual(defaults.object(forKey: "activities.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "activities.media.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "activities.meetings.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "activities.timers.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "activities.downloads.enabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "activities.meetingLeadMinutes") as? Int, 30)
        XCTAssertEqual(defaults.object(forKey: "activities.timerSoundEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "activities.mediaAnimationMode"), "rockHits")
        XCTAssertEqual(defaults.string(forKey: "activities.downloadsFolder"), downloadsFolder.path)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []), [
            "activities.enabled",
            "activities.media.enabled",
            "activities.meetings.enabled",
            "activities.timers.enabled",
            "activities.downloads.enabled",
            "activities.meetingLeadMinutes",
            "activities.timerSoundEnabled",
            "activities.mediaAnimationMode",
            "activities.downloadsFolder"
        ])

        let restored = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(restored.mediaEnabled)
        XCTAssertFalse(restored.meetingsEnabled)
        XCTAssertFalse(restored.timersEnabled)
        XCTAssertFalse(restored.downloadsEnabled)
        XCTAssertEqual(restored.meetingLeadMinutes, 30)
        XCTAssertFalse(restored.timerSoundEnabled)
        XCTAssertEqual(restored.mediaAnimationMode, .rockHits)
        XCTAssertEqual(restored.downloadsFolder, downloadsFolder)
    }

    @MainActor
    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set(7, forKey: "activities.meetingLeadMinutes")
        defaults.set("unsupported", forKey: "activities.mediaAnimationMode")

        let settings = ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)

        XCTAssertEqual(settings.meetingLeadMinutes, 15)
        XCTAssertEqual(settings.mediaAnimationMode, .universal)
    }

    @MainActor
    func testLegacyAnimationModesMigrateToUniversal() {
        for storedValue in ["slow", "fluid"] {
            defaults.set(storedValue, forKey: "activities.mediaAnimationMode")

            XCTAssertEqual(
                ActivitySettings(defaults: defaults, homeDirectory: homeDirectory).mediaAnimationMode,
                .universal
            )
        }
    }

    @MainActor
    func testLegacyStaticAnimationModeMigratesToOff() {
        defaults.set("static", forKey: "activities.mediaAnimationMode")

        XCTAssertEqual(
            ActivitySettings(defaults: defaults, homeDirectory: homeDirectory).mediaAnimationMode,
            .off
        )
    }

    @MainActor
    func testLegacyRockAnimationModeMigratesToRockHits() {
        defaults.set("rock", forKey: "activities.mediaAnimationMode")

        XCTAssertEqual(
            ActivitySettings(defaults: defaults, homeDirectory: homeDirectory).mediaAnimationMode,
            .rockHits
        )
    }

    @MainActor
    func testAllMusicAnimationPresetsAreRestoredFromSettings() {
        let expected: [(String, MediaAnimationMode)] = [
            ("off", .off),
            ("universal", .universal),
            ("rockHits", .rockHits),
            ("rockWall", .rockWall),
            ("electronic", .electronic),
            ("lofi", .lofi)
        ]

        for (storedValue, expectedMode) in expected {
            defaults.set(storedValue, forKey: "activities.mediaAnimationMode")

            XCTAssertEqual(
                ActivitySettings(defaults: defaults, homeDirectory: homeDirectory).mediaAnimationMode,
                expectedMode
            )
        }
    }
}
