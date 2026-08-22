import XCTest
@testable import Cyclop

@MainActor
final class PrivacyModeMigrationTests: XCTestCase {
    func testPreviouslyCoveredAllSectionsAlsoCoversActivitiesAfterUpgrade() {
        let defaults = makeDefaults()
        defaults.set(["clipboard", "snippets", "calendar", "notes"], forKey: PrivacyMode.key)

        let privacy = PrivacyMode(defaults: defaults)

        XCTAssertTrue(privacy.covers(.activities))
        XCTAssertTrue(privacy.coversAll)
        XCTAssertEqual(defaults.integer(forKey: PrivacyMode.schemaVersionKey), 2)
    }

    func testPartialSelectionDoesNotEnableActivitiesDuringMigration() {
        let defaults = makeDefaults()
        defaults.set(["clipboard", "calendar"], forKey: PrivacyMode.key)

        XCTAssertFalse(PrivacyMode(defaults: defaults).covers(.activities))
    }

    func testLegacyBooleanStillCoversAllCurrentSections() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: PrivacyMode.legacyKey)

        XCTAssertTrue(PrivacyMode(defaults: defaults).coversAll)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PrivacyModeMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
