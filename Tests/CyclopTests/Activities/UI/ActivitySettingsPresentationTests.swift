import XCTest
@testable import Cyclop

final class ActivitySettingsPresentationTests: XCTestCase {
    func testApprovedLeadOptionsAndAnimationLabels() {
        XCTAssertEqual(ActivitySettingsPresentation.leadOptions, [5, 10, 15, 30])
        for mode in MediaAnimationMode.allCases {
            XCTAssertFalse(ActivitySettingsPresentation.animationLabel(for: mode).isEmpty)
        }
    }

    func testAutomaticModeHasRussianLabel() {
        XCTAssertEqual(ActivitySettingsPresentation.animationLabel(for: .automatic), "Автоматически по жанру")
    }

    func testFolderDisplayUsesHomeAbbreviation() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Downloads")

        XCTAssertEqual(ActivitySettingsPresentation.displayPath(folder), "~/Downloads")
    }

    @MainActor
    func testInvalidStoredLeadRestoresFifteenMinutes() {
        let suite = "ActivitySettingsPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(99, forKey: "activities.meetingLeadMinutes")
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ActivitySettings(defaults: defaults).meetingLeadMinutes, 15)
    }
}
