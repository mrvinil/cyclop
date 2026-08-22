import AppKit
import SwiftUI

enum ActivitySettingsPresentation {
    static let leadOptions = [5, 10, 15, 30]

    static func animationLabel(for mode: MediaAnimationMode) -> String {
        switch mode {
        case .off: localized("Off")
        case .automatic: "Автоматически по жанру"
        case .universal: localized("Universal")
        case .rockRiff: localized("Rock: Riff")
        case .rockWall: localized("Rock: Wall")
        case .punk: "Панк"
        case .metal: "Металл"
        case .alternativeIndie: "Альтернатива / инди"
        case .pop: "Поп"
        case .dance: "Танцевальная"
        case .electronic: localized("Electronic")
        case .techno: "Техно / house / trance"
        case .breakbeat: "Breakbeat / DnB"
        case .rap: "Рэп"
        case .lofi: localized("Lo-fi")
        case .jazzBlues: "Джаз / блюз"
        case .classical: "Классика"
        case .folk: "Фолк / country / Latin"
        case .cinematic: "Саундтрек / world"
        }
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path == home ? "~" : url.path.replacingOccurrences(of: home + "/", with: "~/")
    }
}

struct ActivitySettingsSection: View {
    @ObservedObject var settings: ActivitySettings
    @State private var folderError: String?

    var body: some View {
        SettingsSection(title: localized("Activity Center")) {
            SettingsToggleRow(symbol: "sparkles.rectangle.stack.fill", title: localized("Activities near notch"), isOn: $settings.isEnabled)
            SettingsToggleRow(symbol: "music.note", title: localized("Music"), isOn: $settings.mediaEnabled)
            SettingsToggleRow(symbol: "calendar", title: localized("Meetings"), isOn: $settings.meetingsEnabled)
            SettingsToggleRow(symbol: "timer", title: localized("Timers"), isOn: $settings.timersEnabled)
            SettingsToggleRow(symbol: "arrow.down.circle", title: localized("Downloads"), isOn: $settings.downloadsEnabled)

            pickerRow(title: localized("Meeting Lead Time")) {
                Picker(localized("Meeting Lead Time"), selection: $settings.meetingLeadMinutes) {
                    ForEach(ActivitySettingsPresentation.leadOptions, id: \.self) { minutes in
                        Text(localized("%d min", minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            SettingsToggleRow(symbol: "speaker.wave.2", title: localized("Timer Sound"), isOn: $settings.timerSoundEnabled)
            pickerRow(title: localized("Music Animation")) {
                Picker(localized("Music Animation"), selection: $settings.mediaAnimationMode) {
                    ForEach(MediaAnimationMode.allCases, id: \.self) { mode in
                        Text(ActivitySettingsPresentation.animationLabel(for: mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            SettingsActionRow(symbol: "folder", title: ActivitySettingsPresentation.displayPath(settings.downloadsFolder)) {
                chooseFolder()
            }
            .accessibilityLabel(Text(localized("Downloads Folder")))
            .accessibilityValue(Text(settings.downloadsFolder.path))

            if let folderError {
                Text(folderError)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
    }

    private func pickerRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = localized("Choose…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isWritableKey])
        guard values?.isDirectory == true,
              values?.isReadable == true,
              values?.isWritable == true else {
            folderError = localized("Folder is not writable")
            return
        }
        folderError = nil
        settings.downloadsFolder = url
    }
}
