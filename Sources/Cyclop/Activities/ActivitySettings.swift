import Combine
import Foundation

enum MediaAnimationMode: String, CaseIterable, Codable {
    case off
    case universal
    case rockHits
    case rockWall
    case electronic
    case lofi
}

@MainActor
final class ActivitySettings: ObservableObject {
    @Published var isEnabled: Bool
    @Published var mediaEnabled: Bool
    @Published var meetingsEnabled: Bool
    @Published var timersEnabled: Bool
    @Published var downloadsEnabled: Bool
    @Published var meetingLeadMinutes: Int
    @Published var timerSoundEnabled: Bool
    @Published var mediaAnimationMode: MediaAnimationMode
    @Published var downloadsFolder: URL

    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let isEnabled = "activities.enabled"
        static let mediaEnabled = "activities.media.enabled"
        static let meetingsEnabled = "activities.meetings.enabled"
        static let timersEnabled = "activities.timers.enabled"
        static let downloadsEnabled = "activities.downloads.enabled"
        static let meetingLeadMinutes = "activities.meetingLeadMinutes"
        static let timerSoundEnabled = "activities.timerSoundEnabled"
        static let mediaAnimationMode = "activities.mediaAnimationMode"
        static let downloadsFolder = "activities.downloadsFolder"
    }

    private static let defaultMeetingLeadMinutes = 15
    private static let allowedMeetingLeadMinutes: Set<Int> = [5, 10, 15, 30]

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        isEnabled = Self.bool(forKey: Key.isEnabled, defaults: defaults, defaultValue: true)
        mediaEnabled = Self.bool(forKey: Key.mediaEnabled, defaults: defaults, defaultValue: true)
        meetingsEnabled = Self.bool(forKey: Key.meetingsEnabled, defaults: defaults, defaultValue: true)
        timersEnabled = Self.bool(forKey: Key.timersEnabled, defaults: defaults, defaultValue: true)
        downloadsEnabled = Self.bool(forKey: Key.downloadsEnabled, defaults: defaults, defaultValue: true)

        let storedMeetingLeadMinutes = defaults.object(forKey: Key.meetingLeadMinutes) as? Int
        meetingLeadMinutes = Self.allowedMeetingLeadMinutes.contains(storedMeetingLeadMinutes ?? 0)
            ? storedMeetingLeadMinutes!
            : Self.defaultMeetingLeadMinutes

        timerSoundEnabled = Self.bool(forKey: Key.timerSoundEnabled, defaults: defaults, defaultValue: true)
        mediaAnimationMode = Self.mediaAnimationMode(for: defaults.string(forKey: Key.mediaAnimationMode))
        downloadsFolder = defaults.string(forKey: Key.downloadsFolder)
            .map(URL.init(fileURLWithPath:)) ?? homeDirectory.appendingPathComponent("Downloads")

        $isEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.isEnabled) }
            .store(in: &cancellables)
        $mediaEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.mediaEnabled) }
            .store(in: &cancellables)
        $meetingsEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.meetingsEnabled) }
            .store(in: &cancellables)
        $timersEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.timersEnabled) }
            .store(in: &cancellables)
        $downloadsEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.downloadsEnabled) }
            .store(in: &cancellables)
        $meetingLeadMinutes
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.meetingLeadMinutes) }
            .store(in: &cancellables)
        $timerSoundEnabled
            .dropFirst()
            .sink { defaults.set($0, forKey: Key.timerSoundEnabled) }
            .store(in: &cancellables)
        $mediaAnimationMode
            .dropFirst()
            .sink { defaults.set($0.rawValue, forKey: Key.mediaAnimationMode) }
            .store(in: &cancellables)
        $downloadsFolder
            .dropFirst()
            .sink { defaults.set($0.path, forKey: Key.downloadsFolder) }
            .store(in: &cancellables)
    }

    private static func bool(forKey key: String, defaults: UserDefaults, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func mediaAnimationMode(for storedValue: String?) -> MediaAnimationMode {
        switch storedValue {
        case "static": .off
        case "slow", "fluid": .universal
        case "rock": .rockHits
        default: storedValue.flatMap(MediaAnimationMode.init(rawValue:)) ?? .universal
        }
    }
}
