import SwiftUI

enum TimerComposerDraftError: Error, Equatable {
    case invalidDuration
}

struct TimerComposerDraft: Equatable {
    static let presetMinutes = [5, 10, 25, 45, 60]
    static let maximumDuration: TimeInterval = 359_999

    var name: String
    var hours: String
    var minutes: String
    var seconds: String

    init(name: String = "", hours: String = "", minutes: String = "", seconds: String = "") {
        self.name = name
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localized("Timer")
            : name
    }

    func duration() throws -> TimeInterval {
        let hours = try component(hours)
        let minutes = try component(minutes)
        let seconds = try component(seconds)

        let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
        let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
        let (withoutSeconds, minuteAdditionOverflow) = hourSeconds.addingReportingOverflow(minuteSeconds)
        let (total, totalOverflow) = withoutSeconds.addingReportingOverflow(seconds)
        guard !hourOverflow,
              !minuteOverflow,
              !minuteAdditionOverflow,
              !totalOverflow,
              (1 ... Int64(Self.maximumDuration)).contains(total) else {
            throw TimerComposerDraftError.invalidDuration
        }
        return TimeInterval(total)
    }

    mutating func selectPreset(minutes: Int) {
        hours = ""
        self.minutes = String(minutes)
        seconds = ""
    }

    mutating func reset() {
        self = Self()
    }

    private func component(_ rawValue: String) throws -> Int64 {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }
        guard let component = Int64(value), component >= 0 else {
            throw TimerComposerDraftError.invalidDuration
        }
        return component
    }
}

struct TimerComposer: View {
    @ObservedObject var model: ActivityCenterViewModel
    @Binding var wantsKeyboard: Bool

    @State private var draft = TimerComposerDraft()
    @State private var fieldError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("New Timer"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            TextField(localized("Timer name"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .onTapGesture { wantsKeyboard = true }
                .onChange(of: draft.name) { _, _ in fieldError = nil }

            HStack(spacing: 5) {
                ForEach(TimerComposerDraft.presetMinutes, id: \.self) { minutes in
                    Button("\(minutes) \(localized("min"))") {
                        draft.selectPreset(minutes: minutes)
                        fieldError = nil
                    }
                    .buttonStyle(ActivityControlButtonStyle())
                }
            }

            HStack(spacing: 6) {
                durationField(localized("h"), text: $draft.hours)
                durationField(localized("min"), text: $draft.minutes)
                durationField(localized("s"), text: $draft.seconds)
            }

            if let fieldError {
                Text(fieldError)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(fieldError))
            }

            HStack(spacing: 7) {
                Button(localized("Create"), action: submit)
                    .buttonStyle(ActivityControlButtonStyle(prominent: true))
                Button(localized("Cancel"), action: cancel)
                    .buttonStyle(ActivityControlButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func durationField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .onTapGesture { wantsKeyboard = true }
            .onChange(of: text.wrappedValue) { _, _ in fieldError = nil }
    }

    private func submit() {
        let duration: TimeInterval
        do {
            duration = try draft.duration()
        } catch {
            publishInvalidDuration()
            return
        }

        do {
            try model.createTimer(name: draft.normalizedName, duration: duration)
            draft.reset()
            fieldError = nil
            model.timerComposerPresented = false
            wantsKeyboard = false
        } catch {
            fieldError = model.transientError
        }
    }

    private func publishInvalidDuration() {
        do {
            try model.createTimer(name: draft.normalizedName, duration: 0)
        } catch {
            fieldError = model.transientError
        }
    }

    private func cancel() {
        model.timerComposerPresented = false
        wantsKeyboard = false
    }
}
