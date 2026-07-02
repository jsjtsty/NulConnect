import AppKit
import Combine
import SwiftUI

enum NulConnectWindowRole: String, Sendable {
    case main
    case settings
}

@MainActor
final class NulConnectWindowCoordinator: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private var visibleWindowCount = 0
    private var observers: [ObjectIdentifier: NulConnectWindowObserver] = [:]

    func register(window: NSWindow, role: NulConnectWindowRole) {
        purgeReleasedWindows()
        let key = ObjectIdentifier(window)
        if let observer = observers[key] {
            observer.role = role
            return
        }

        if let existingWindow = primaryWindow(for: role), existingWindow !== window {
            window.close()
            updateVisibleWindowCount()
            return
        }

        let observer = NulConnectWindowObserver(window: window, role: role, coordinator: self)
        observers[key] = observer
        window.delegate = observer
        updateVisibleWindowCount()
    }

    @discardableResult
    func activateForPresentation(role: NulConnectWindowRole? = nil) -> Bool {
        NSApp.setActivationPolicy(.regular)
        var didShowWindow = false
        if let role {
            didShowWindow = showWindow(role: role)
        }
        NSApp.activate(ignoringOtherApps: true)
        return didShowWindow
    }

    func unregister(window: NSWindow) {
        observers.removeValue(forKey: ObjectIdentifier(window))
        updateVisibleWindowCount()
    }

    private func showWindow(role: NulConnectWindowRole) -> Bool {
        purgeReleasedWindows()
        guard let window = primaryWindow(for: role) else {
            updateVisibleWindowCount()
            return false
        }

        for observer in observers.values where observer.role == role && observer.window !== window {
            observer.window?.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        updateVisibleWindowCount()
        return true
    }

    private func primaryWindow(for role: NulConnectWindowRole) -> NSWindow? {
        observers.values
            .compactMap { observer -> NSWindow? in
                guard observer.role == role else {
                    return nil
                }
                return observer.window
            }
            .first
    }

    private func purgeReleasedWindows() {
        observers = observers.filter { _, observer in
            observer.window != nil
        }
    }

    private func updateVisibleWindowCount() {
        let nextVisibleWindowCount = observers.values.filter { observer in
            guard let window = observer.window else {
                return false
            }
            return window.isVisible && !window.isMiniaturized
        }.count
        guard nextVisibleWindowCount != visibleWindowCount else {
            return
        }
        visibleWindowCount = nextVisibleWindowCount

        let desiredPolicy: NSApplication.ActivationPolicy = visibleWindowCount > 0 ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }
}

@MainActor
private final class NulConnectWindowObserver: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    weak var coordinator: NulConnectWindowCoordinator?
    var role: NulConnectWindowRole

    init(window: NSWindow, role: NulConnectWindowRole, coordinator: NulConnectWindowCoordinator) {
        self.window = window
        self.role = role
        self.coordinator = coordinator
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        coordinator?.unregister(window: window)
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
