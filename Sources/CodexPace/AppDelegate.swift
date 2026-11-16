import AppKit
import Combine
import QuotaCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: TrackerModel
    private let showOnLaunch: Bool
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var displayTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationPending = false

    init(model: TrackerModel, showOnLaunch: Bool) {
        self.model = model
        self.showOnLaunch = showOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.stopDisplayTimer()
                self?.model.suspend()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
                self?.startDisplayTimer()
                self?.model.resume()
            }
        })
        startDisplayTimer()
        updateStatus()
        model.start()
        if showOnLaunch { togglePopover() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.updateLoginItemStatus()
            let controller = NSHostingController(rootView: TrackerView(model: model))
            // Follow the disclosure's ideal height in both directions.
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the view and its display-only timeline while the menu is closed.
        popover.contentViewController = nil
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let now = Date()
        let window = model.selectedWindow
        let presentation = MenuBarPresentation(
            mode: model.menuBarDisplayMode, window: window,
            isStale: model.isStale(at: now), at: now
        )
        button.title = " " + presentation.title
        button.image = statusImage(window: window, at: now, isPaceUnavailable: presentation.isPaceUnavailable)
        var detail = presentation.summary
        if let error = model.errorMessage { detail += " · " + error }
        button.toolTip = detail
        button.setAccessibilityLabel(detail)
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        // The pace changes with time even when no quota has been spent.
        // This timer only redraws; it never makes a quota request.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func statusImage(window: QuotaWindow?, at now: Date, isPaceUnavailable: Bool) -> NSImage? {
        if model.errorMessage != nil {
            return NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Refresh failed")
        }
        guard let window else {
            return NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex quota")
        }
        if model.menuBarDisplayMode == .paceBalance, isPaceUnavailable {
            return NSImage(systemSymbolName: model.isStale(at: now) ? "clock" : "minus.circle", accessibilityDescription: "Pace unavailable")
        }
        let remaining = window.remainingPercent / 100
        let target = PaceMetrics(window: window, at: now).targetRemainingPercent.map { $0 / 100 }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 18, height: 10), xRadius: 2, yRadius: 2).fill()
            NSColor.labelColor.setFill()
            if remaining > 0 {
                NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 18 * remaining, height: 10), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let target {
                let marker = NSBezierPath()
                marker.move(to: NSPoint(x: 1 + 18 * target, y: 2))
                marker.line(to: NSPoint(x: 1 + 18 * target, y: 16))
                marker.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                marker.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        stopDisplayTimer()
        Task {
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDisplayTimer()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
