import AppKit
import Carbon.HIToolbox
import QuickLookUI

@MainActor
final class CarbonShelfPreviewHotKey: ShelfPreviewHotKeyHandling {
    var onPress: (() -> Void)?

    private var registration: CarbonSpaceHotKeyRegistration?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard registration == nil else { return }
            registration = CarbonSpaceHotKeyRegistration { [weak self] in
                self?.onPress?()
            }
        } else {
            registration = nil
        }
    }
}

/// Carbon's hot-key API is used deliberately here instead of an NSEvent global
/// monitor: a monitor can only observe Space after the underlying application
/// receives it and key monitoring requires Accessibility permission. The hot
/// key is registered only while a shelf card or its preview owns the gesture.
private final class CarbonSpaceHotKeyRegistration {
    private static let signature: OSType = 0x43595350 // "CYSP"
    private static let identifier: UInt32 = 1

    private let onPress: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init?(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == CarbonSpaceHotKeyRegistration.signature,
              hotKeyID.id == CarbonSpaceHotKeyRegistration.identifier else {
            return OSStatus(eventNotHandledErr)
        }
        let registration = Unmanaged<CarbonSpaceHotKeyRegistration>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in registration.onPress() }
        return noErr
    }
}

@MainActor
final class QuickLookShelfPreviewPresenter: NSObject, ShelfPreviewPresenting, NSWindowDelegate {
    var onClose: (() -> Void)?
    private(set) var isVisible = false

    private var panel: NSPanel?
    private var previewView: QLPreviewView?

    func show(_ url: URL) {
        let (panel, previewView) = previewWindow()
        previewView.previewItem = url as NSURL
        panel.orderFrontRegardless()
        isVisible = true
    }

    func close() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        finishClosing()
    }

    private func finishClosing() {
        guard isVisible else { return }
        isVisible = false
        previewView?.previewItem = nil
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        finishClosing()
        panel = nil
        previewView = nil
    }

    private func previewWindow() -> (NSPanel, QLPreviewView) {
        if let panel, let previewView { return (panel, previewView) }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(
            width: min(1100, visibleFrame.width * 0.72),
            height: min(780, visibleFrame.height * 0.78)
        )
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = ShelfQuickLookPanel(contentRect: frame)
        let previewView = QLPreviewView(frame: panel.contentView?.bounds ?? .zero, style: .normal)!
        previewView.autoresizingMask = [.width, .height]
        panel.contentView = previewView
        panel.delegate = self
        panel.onCloseRequest = { [weak self] in self?.close() }

        self.panel = panel
        self.previewView = previewView
        return (panel, previewView)
    }
}

private final class ShelfQuickLookPanel: NSPanel {
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The standard close path tears down QLPreviewView while AppKit's window
    /// transform still retains it. Treat the title-bar button exactly like the
    /// Space toggle: hide the reusable panel and let its owner clear the item.
    override func performClose(_ sender: Any?) {
        onCloseRequest?()
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = localized("Preview")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = true
        minSize = NSSize(width: 480, height: 320)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let closeButton = standardWindowButton(.closeButton)
        closeButton?.target = self
        closeButton?.action = #selector(performClose(_:))
    }
}

extension ShelfPreviewCoordinator {
    convenience init() {
        self.init(
            hotKey: CarbonShelfPreviewHotKey(),
            presenter: QuickLookShelfPreviewPresenter()
        )
    }
}
