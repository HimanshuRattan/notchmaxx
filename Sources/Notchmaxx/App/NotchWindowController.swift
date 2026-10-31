import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the transparent panel pinned over the notch. The panel ignores the mouse while
/// collapsed so the menu bar keeps working; hover is tracked with event monitors instead.
@MainActor
final class NotchWindowController {
    let model = NotchModel()

    private let store: UsageStore
    private let actions: NotchActions
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var alertWork: DispatchWorkItem?
    private var alertQueue: [AlertItem] = []
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollStep = Date.distantPast

    private static let windowSize = CGSize(width: 760, height: 760)
    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    init(store: UsageStore, actions: NotchActions) {
        self.store = store
        self.actions = actions
    }

    func show() {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = FirstMouseHostingView(rootView: NotchRootView(model: model, store: store, settings: .shared, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        position()
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    func position() {
        guard let panel, let screen = Self.preferredScreen() else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            model.hasPhysicalNotch = true
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            model.notchSize = CGSize(width: 190, height: max(menuBar, 24))
            model.hasPhysicalNotch = false
        }
        let size = Self.windowSize
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Hit testing

    private var shellRect: NSRect {
        guard let panel else { return .zero }
        let size = model.shellSize == .zero ? model.notchSize : model.shellSize
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    private var notchRect: NSRect {
        guard let panel else { return .zero }
        let n = model.notchSize
        let f = panel.frame
        return NSRect(x: f.midX - n.width / 2, y: f.maxY - n.height, width: n.width, height: n.height)
    }

    private var hotRect: NSRect {
        // While collapsed, the notch plus any pill wings, grown a little so it is easy to hit
        // from the top edge of the screen.
        let base = model.presentation == .collapsed ? shellRect.union(notchRect) : shellRect
        return base.insetBy(dx: -6, dy: -4)
    }

    // MARK: - Events

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .leftMouseDown], handler: { [weak self] event in
            // Local monitors run on the main thread. Decide there, but keep the event itself
            // on this side so it never crosses an isolation boundary.
            let type = event.type
            // Scroll properties raise an exception on any other event type, which would make
            // AppKit drop the click, so only read them for scroll events.
            let scroll = type == .scrollWheel
                ? (dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                   phase: event.phase, momentum: event.momentumPhase)
                : (dx: 0, dy: 0, precise: true, phase: [], momentum: [])
            let inPanel = event.window != nil && event.window === self?.panel
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                switch type {
                case .scrollWheel:
                    return self.handleScroll(dx: scroll.dx, dy: scroll.dy, precise: scroll.precise,
                                             phase: scroll.phase, momentum: scroll.momentum, inPanel: inPanel)
                case .leftMouseDown:
                    return self.handleClick(inPanel: inPanel)
                default:
                    self.trackMouse()
                    return false
                }
            }
            return consumed ? nil : event
        }) {
            monitors.append(local)
        }
        // Monitors miss some exits, such as the pointer jumping to another display.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func trackMouse() {
        let point = NSEvent.mouseLocation
        switch model.presentation {
        case .collapsed, .alert:
            if hotRect.contains(point) {
                guard openWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.hotRect.contains(NSEvent.mouseLocation) { self.expand() }
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                openWork?.cancel()
                openWork = nil
            }
        case .expanded:
            if shellRect.insetBy(dx: -14, dy: -14).contains(point) {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.shellRect.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) { self.collapse() }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    /// Returns true when the scroll was used to switch tabs.
    private func handleScroll(dx rawDX: CGFloat, dy rawDY: CGFloat, precise: Bool,
                              phase: NSEvent.Phase, momentum: NSEvent.Phase, inPanel: Bool) -> Bool {
        guard model.presentation == .expanded, inPanel else { return false }
        if !momentum.isEmpty { return true }
        let scale: CGFloat = precise ? 1 : 12
        let dx = rawDX * scale
        let dy = rawDY * scale
        scrollAccumulator += abs(dx) > abs(dy) ? -dx : -dy
        if abs(scrollAccumulator) > 34, Date().timeIntervalSince(lastScrollStep) > 0.32 {
            model.step(scrollAccumulator > 0 ? 1 : -1)
            scrollAccumulator = 0
            lastScrollStep = Date()
        }
        if phase == .ended || phase == .cancelled { scrollAccumulator = 0 }
        return true
    }

    /// Clicking the notch itself opens the usage window.
    private func handleClick(inPanel: Bool) -> Bool {
        guard inPanel, notchRect.contains(NSEvent.mouseLocation) else { return false }
        actions.openUsage()
        return true
    }

    // MARK: - States

    func expand() {
        closeWork?.cancel()
        closeWork = nil
        alertWork?.cancel()
        alertWork = nil
        withAnimation(Self.spring) {
            model.alert = nil
            model.presentation = .expanded
        }
        panel?.ignoresMouseEvents = false
        store.refreshIfStale()
    }

    func collapse() {
        alertWork?.cancel()
        alertWork = nil
        withAnimation(Self.spring) {
            model.presentation = .collapsed
            model.alert = nil
        }
        panel?.ignoresMouseEvents = true
        if !alertQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.showNextAlert() }
        }
    }

    func present(_ alert: AlertItem) {
        alertQueue.append(alert)
        if model.presentation == .collapsed { showNextAlert() }
    }

    private func showNextAlert() {
        guard model.presentation == .collapsed, !alertQueue.isEmpty else { return }
        let alert = alertQueue.removeFirst()
        withAnimation(Self.spring) {
            model.alert = alert
            model.presentation = .alert
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.presentation == .alert else { return }
            self.collapse()
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
