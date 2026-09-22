import AppKit
import Combine
import SwiftUI

/// Manages the NSStatusItem (menu bar icon) and the popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = EnvironmentModel()

    // For the green flash effect
    private var flashTimer: Timer?

    // Keep Combine subscriptions alive.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (agent app).
        NSApp.setActivationPolicy(.accessory)

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))

        // Hook up icon colour updates when an environment wakes.
        model.onEnvironmentWokeUp = { [weak self] in
            self?.flashGreen()
        }

        // Observe model changes for icon colour.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateIcon()
                }
            }
            .store(in: &cancellables)

        // Request notification permission now that the app is running.
        model.requestNotificationPermission()

        // On first launch the model sets showSettings = true,
        // so the settings view appears automatically on first click.
        // If the user has no programs at all, show the popover immediately.
        if model.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPopover()
            }
        }
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Menu bar icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let color: NSColor

        if model.anyWatching {
            color = .systemOrange
        } else if model.programs.flatMap(\.environments).contains(where: { $0.status == .up }) {
            color = .systemGreen
        } else {
            color = .systemGray
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "AEM Monitor") {
            let tinted = image.withSymbolConfiguration(config)
            button.image = tinted
            button.contentTintColor = color
        }
    }

    private func flashGreen() {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = .systemGreen

        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
            }
        }
    }
}
