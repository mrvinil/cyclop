import SwiftUI

struct DownloadComposerDraft: Equatable {
    var urlText: String

    init(urlText: String = "") {
        self.urlText = urlText
    }

    var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func reset() {
        self = Self()
    }
}

struct DownloadComposer: View {
    @ObservedObject var model: ActivityCenterViewModel
    @Binding var wantsKeyboard: Bool
    @Binding var isPresented: Bool

    @State private var draft = DownloadComposerDraft()
    @State private var fieldError: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("Download from Link"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            TextField(localized("HTTPS Link"), text: $draft.urlText)
                .textFieldStyle(.roundedBorder)
                .onTapGesture { wantsKeyboard = true }
                .onChange(of: draft.urlText) { _, _ in fieldError = nil }

            if isDropTargeted {
                Text(localized("Drop link here"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }

            if let fieldError {
                Text(fieldError)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(fieldError))
            }

            HStack(spacing: 7) {
                Button(localized("Download"), action: submit)
                    .buttonStyle(ActivityControlButtonStyle(prominent: true))
                Button(localized("Cancel"), action: cancel)
                    .buttonStyle(ActivityControlButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isDropTargeted ? Theme.surfaceHover : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedURL(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .onAppear {
            if draft.urlText.isEmpty, !model.downloadURL.isEmpty {
                draft.urlText = model.downloadURL
            }
        }
    }

    private func submit() {
        model.downloadURL = draft.trimmedURL
        do {
            try model.enqueueDownload()
            draft.reset()
            fieldError = nil
        } catch {
            fieldError = model.transientError
        }
    }

    private func acceptDroppedURL(_ urls: [URL]) -> Bool {
        guard urls.count == 1,
              let url = urls.first,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            fieldError = localized("Paste an HTTP or HTTPS link")
            return false
        }

        draft.urlText = url.absoluteString
        fieldError = nil
        return true
    }

    private func cancel() {
        isPresented = false
        wantsKeyboard = false
    }
}
