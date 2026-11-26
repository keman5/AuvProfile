import AppKit
import SwiftUI

@MainActor
final class WindowLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static let hideDockDefaultsKey = "settings.hideDockOnClose"
    @Published private(set) var showsTabFocus = false
    private var focusMonitor: Any?
    private weak var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var profilePanel: MenuBarPanel?

    var hideDockOnClose: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.hideDockDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.hideDockDefaultsKey)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.hideDockDefaultsKey)
            if !newValue {
                NSApp.setActivationPolicy(.regular)
            } else if mainWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetTabFocus), name: NSWindow.didBecomeKeyNotification, object: nil
        )
        focusMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.updateTabFocus(for: event)
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
    }

    func updateTabFocus(for event: NSEvent) {
        if event.type != .keyDown {
            resetTabFocus()
        } else if event.keyCode == 48, !showsTabFocus,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            showsTabFocus = true
        }
    }

    @objc private func resetTabFocus() {
        if showsTabFocus { showsTabFocus = false }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func register(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: mainWindow)
        mainWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    func installStatusItem(manager: ProfileManager, openMainWindow: @escaping (Client, MainWindowAction) -> Void) {
        guard statusItem == nil else { return }

        let hostingController = NSHostingController(rootView: MenuBarProfiles(
            manager: manager,
            openMainWindow: { [weak self] client, action in
                self?.profilePanel?.orderOut(nil)
                NSApp.setActivationPolicy(.regular)
                openMainWindow(client, action)
                NSApp.activate()
            },
            closePanel: { [weak self] in self?.profilePanel?.orderOut(nil) }
        ).modifier(TabFocusEffect(lifecycle: self)))
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        profilePanel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: "AuvProfile")
            button.toolTip = "AuvProfile"
            button.setAccessibilityLabel("AuvProfile")
            button.target = self
            button.action = #selector(toggleProfilePanel(_:))
        }
        statusItem = item
    }

    @objc private func toggleProfilePanel(_ button: NSStatusBarButton) {
        guard let panel = profilePanel, let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let available = screen.visibleFrame
        let width = panel.frame.width
        let x = min(max(anchor.midX - width / 2, available.minX + 8), available.maxX - width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 5))
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? MenuBarPanel else { return }
        panel.orderOut(nil)
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        if hideDockOnClose {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct TabFocusEffect: ViewModifier {
    @ObservedObject var lifecycle: WindowLifecycle

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled(!lifecycle.showsTabFocus)
            .environmentObject(lifecycle)
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MainWindowRegistration: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let lifecycle: WindowLifecycle
    let manager: ProfileManager
    let routeToMainWindow: (Client, MainWindowAction) -> Void

    func makeNSView(context: Context) -> WindowObserver {
        let openWindow = self.openWindow
        let routeToMainWindow = self.routeToMainWindow
        lifecycle.installStatusItem(manager: manager) { client, action in
            routeToMainWindow(client, action)
            openWindow(id: "profiles")
        }
        return WindowObserver(lifecycle: lifecycle)
    }

    func updateNSView(_ view: WindowObserver, context: Context) {}

    final class WindowObserver: NSView {
        private weak var lifecycle: WindowLifecycle?

        init(lifecycle: WindowLifecycle) {
            self.lifecycle = lifecycle
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { lifecycle?.register(window) }
        }
    }
}
