import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore.shared
    private let settings = SettingsStore.shared
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = NotchActions(
            openUsage: { [weak self] in self?.openUsage() },
            openSettings: { [weak self] in self?.openSettings() },
            openSetup: { [weak self] in self?.openSetup() },
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.refreshAll() }
            }
        )
        let notch = NotchWindowController(store: store, actions: actions)
        self.notch = notch
        store.onAlert = { [weak notch] alert in notch?.present(alert) }
        notch.show()

        settings.onChange = { [weak self] old, new in
            guard let self else { return }
            if old.claudeConfigDirs != new.claudeConfigDirs || old.codexHomes != new.codexHomes || old.cursorEnabled != new.cursorEnabled {
                Task { await self.store.refreshAll() }
            } else {
                self.store.rebuild()
            }
            if old.showMenuBarIcon != new.showMenuBarIcon { self.updateStatusItem() }
        }
        updateStatusItem()
        store.start()

        if !settings.value.setupCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openSetup() }
        }
    }

    // MARK: - Status item

    private func updateStatusItem() {
        guard settings.value.showMenuBarIcon else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Notchmaxx")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open usage", action: #selector(menuUsage), keyEquivalent: "u").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup assistant…", action: #selector(menuSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh now", action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchmaxx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func menuUsage() { openUsage() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuSetup() { openSetup() }
    @objc private func menuRefresh() { Task { await store.refreshAll() } }

    // MARK: - Windows

    func openUsage() {
        notch?.collapse()
        present("usage", title: "Usage", size: NSSize(width: 760, height: 860)) {
            UsageWindowView(store: self.store)
        }
    }

    func openSettings() {
        notch?.collapse()
        present("settings", title: "Notchmaxx Settings", size: NSSize(width: 560, height: 720)) {
            SettingsView(settings: self.settings, store: self.store, openSetup: { [weak self] in self?.openSetup() })
        }
    }

    func openSetup() {
        notch?.collapse()
        present("setup", title: "Setup", size: NSSize(width: 560, height: 600), resizable: false) {
            SetupView(
                store: self.store,
                openSettings: { [weak self] in self?.openSettings() },
                done: { [weak self] in
                    self?.settings.value.setupCompleted = true
                    self?.windows["setup"]?.close()
                })
        }
    }

    private func present<Content: View>(_ key: String, title: String, size: NSSize, resizable: Bool = true, content: () -> Content) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
