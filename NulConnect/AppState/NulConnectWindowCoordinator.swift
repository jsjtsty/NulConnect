import AppKit
import Combine
import SwiftUI

enum NulConnectWindowRole: String, CaseIterable, Sendable {
    case main
    case settings

    var windowIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("NulConnect.\(rawValue)")
    }
}

@MainActor
final class NulConnectWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let objectWillChange = ObservableObjectPublisher()

    private var notificationTokens: [NSObjectProtocol] = []
    private let managedWindowIdentifiers = Set(NulConnectWindowRole.allCases.map(\.windowIdentifier))

    override init() {
        super.init()
        observeWindowVisibility(NSWindow.willCloseNotification)
        observeWindowVisibility(NSWindow.didMiniaturizeNotification)
        observeWindowVisibility(NSWindow.didDeminiaturizeNotification)
        observeWindowVisibility(NSWindow.didBecomeKeyNotification)
        observeWindowVisibility(NSWindow.didResignKeyNotification)
    }

    func register(window: NSWindow, role: NulConnectWindowRole) {
        guard window.identifier != role.windowIdentifier else {
            return
        }

        window.identifier = role.windowIdentifier
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        if role == .main {
            window.delegate = self
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        }
        scheduleDockPolicyUpdate(afterNanoseconds: 0, allowsAccessoryPolicy: false)
        scheduleDockPolicyUpdate(afterNanoseconds: 150_000_000, allowsAccessoryPolicy: false)
        if role == .settings {
            DispatchQueue.main.async {
                window.makeFirstResponder(nil)
            }
        }
    }

    @discardableResult
    func activateForPresentation(role: NulConnectWindowRole? = nil) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        var didShowWindow = false
        if let role {
            didShowWindow = showVisibleWindow(role: role)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        return didShowWindow
    }

    func updateVisibilityAfterPresentation() {
        scheduleDockPolicyUpdate(afterNanoseconds: 0, allowsAccessoryPolicy: false)
        scheduleDockPolicyUpdate(afterNanoseconds: 250_000_000, allowsAccessoryPolicy: false)
    }

    private func showVisibleWindow(role: NulConnectWindowRole) -> Bool {
        guard let window = visibleManagedWindows(role: role).first else {
            return false
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.center()
        scheduleDockPolicyUpdate(afterNanoseconds: 0, allowsAccessoryPolicy: false)
        return true
    }

    private func observeWindowVisibility(_ name: Notification.Name) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else {
                return
            }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.handleWindowVisibilityChange(window)
            }
        }
        notificationTokens.append(token)
    }

    private func handleWindowVisibilityChange(_ window: NSWindow) {
        guard isManagedWindow(window) else {
            return
        }
        scheduleDockPolicyUpdate(afterNanoseconds: 100_000_000, allowsAccessoryPolicy: true)
    }

    private func scheduleDockPolicyUpdate(afterNanoseconds delay: UInt64, allowsAccessoryPolicy: Bool) {
        Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                await Task.yield()
            }
            self?.updateDockPolicy(allowsAccessoryPolicy: allowsAccessoryPolicy)
        }
    }

    private func updateDockPolicy(allowsAccessoryPolicy: Bool) {
        let hasVisibleManagedWindow = !visibleManagedWindows().isEmpty
        guard hasVisibleManagedWindow || allowsAccessoryPolicy else {
            return
        }

        let desiredPolicy: NSApplication.ActivationPolicy = hasVisibleManagedWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }

    private func visibleManagedWindows(role: NulConnectWindowRole? = nil) -> [NSWindow] {
        NSApp.windows.filter { window in
            guard isManagedWindow(window), window.isVisible, !window.isMiniaturized else {
                return false
            }
            if let role {
                return window.identifier == role.windowIdentifier
            }
            return true
        }
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier else {
            return false
        }
        return managedWindowIdentifiers.contains(identifier)
    }

    func windowWillMiniaturize(_ notification: Notification) {
        guard let sender = notification.object as? NSWindow,
              sender.identifier == NulConnectWindowRole.main.windowIdentifier else {
            return
        }

        DispatchQueue.main.async {
            if sender.isMiniaturized {
                sender.deminiaturize(nil)
            }
        }
    }
}

struct NulConnectWindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Task { @MainActor in
                    onResolve(window)
                }
            }
        }
    }
}
