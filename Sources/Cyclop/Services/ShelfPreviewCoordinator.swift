import Foundation

@MainActor
protocol ShelfPreviewHotKeyHandling: AnyObject {
    var onPress: (() -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
}

@MainActor
protocol ShelfPreviewPresenting: AnyObject {
    var onClose: (() -> Void)? { get set }
    var isVisible: Bool { get }
    func show(_ url: URL)
    func close()
}

/// Connects the card under the pointer with the system Quick Look shortcut.
/// The preview owns the shortcut while it is visible, so moving the pointer
/// into the preview cannot leave the user without a way to close it.
@MainActor
final class ShelfPreviewCoordinator {
    private let hotKey: ShelfPreviewHotKeyHandling
    private let presenter: ShelfPreviewPresenting
    private var hoveredURL: URL?

    init(hotKey: ShelfPreviewHotKeyHandling, presenter: ShelfPreviewPresenting) {
        self.hotKey = hotKey
        self.presenter = presenter
        hotKey.onPress = { [weak self] in self?.toggle() }
        presenter.onClose = { [weak self] in self?.refreshHotKey() }
    }

    func setHoveredURL(_ url: URL?) {
        hoveredURL = url
        refreshHotKey()
    }

    func updateAvailableURLs(_ urls: [URL]) {
        guard let hoveredURL, !urls.contains(hoveredURL) else { return }
        self.hoveredURL = nil
        refreshHotKey()
    }

    func stop() {
        hoveredURL = nil
        presenter.close()
        hotKey.setEnabled(false)
    }

    private func toggle() {
        if presenter.isVisible {
            presenter.close()
        } else if let hoveredURL {
            presenter.show(hoveredURL)
        }
        refreshHotKey()
    }

    private func refreshHotKey() {
        hotKey.setEnabled(hoveredURL != nil || presenter.isVisible)
    }
}
