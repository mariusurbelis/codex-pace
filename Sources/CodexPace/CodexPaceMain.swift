import AppKit
import CodexUsage
import Foundation
import QuotaCore
import ServiceManagement
import SwiftUI

@main
enum CodexPaceMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Codex Pace — a local macOS menu bar quota tracker

            Usage: CodexPace [--show] [--cli /absolute/path/to/codex]
                   CodexPace --once [--cli /absolute/path/to/codex]
                   CodexPace --demo [--show]
                   CodexPace --launch-at-login enable|disable|status
                   CodexPace --preview /absolute/path.png [--dark] [--details] [--preview-state ahead|behind|balanced|missing|expired|stale|failure|empty|disconnected|multiple|zero|full]

            --once     Read current quota as JSON, then exit. No model generation.
            --show     Open the menu bar popover on launch.
            --demo     Display a sample weekly window without network requests.
            --preview  Render the sample popover to PNG, then exit.
            --details  Expand More details in a preview.
            --preview-state  Choose a local preview fixture (also works with --demo).
            --cli      Use a particular Codex executable for this invocation.
            --launch-at-login  Manage the bundled app's login item, then exit.
            """)
            return
        }
        let valuedOptions = ["--cli", "--preview", "--preview-state", "--launch-at-login"]
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valuedOptions.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    fail(argument == "--launch-at-login" ? "--launch-at-login requires enable, disable, or status." : "\(argument) requires a path.")
                }
                values[argument] = arguments[index + 1]
                index += 2
            } else if ["--once", "--show", "--demo", "--dark", "--details"].contains(argument) {
                flags.insert(argument)
                index += 1
            } else {
                fail("Unknown option: \(argument). Use --help.")
            }
        }
        if let action = values["--launch-at-login"] {
            guard ["enable", "disable", "status"].contains(action) else {
                fail("--launch-at-login requires enable, disable, or status.")
            }
            guard values.count == 1, flags.isEmpty else {
                fail("Use --launch-at-login separately from other options.")
            }
            manageLaunchAtLogin(action)
            return
        }
        let scenario: PreviewScenario
        if let state = values["--preview-state"] {
            guard let value = PreviewScenario(rawValue: state) else {
                fail("Unknown preview state: \(state). Use --help.")
            }
            guard values["--preview"] != nil || flags.contains("--demo") else {
                fail("--preview-state requires --preview or --demo.")
            }
            scenario = value
        } else {
            scenario = .ahead
        }
        if flags.contains("--details"), values["--preview"] == nil {
            fail("--details requires --preview.")
        }
        if flags.contains("--once") {
            guard !flags.contains("--demo"), values["--preview"] == nil else {
                fail("Use --once separately from --demo and --preview.")
            }
            let override = values["--cli"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            Task {
                do {
                    let snapshot = try await CodexUsageClient(executableURL: override).fetch()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(snapshot)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    exit(0)
                } catch {
                    fail((error as? LocalizedError)?.errorDescription ?? "Usage could not be read.")
                }
            }
            dispatchMain()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let output = values["--preview"] {
            renderPreview(to: output, dark: flags.contains("--dark"), details: flags.contains("--details"), scenario: scenario)
            return
        }
        let model = TrackerModel(isDemo: flags.contains("--demo"), cliPath: values["--cli"], demoScenario: scenario)
        let delegate = AppDelegate(model: model, showOnLaunch: flags.contains("--show"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func manageLaunchAtLogin(_ action: String) {
        let bundleURL = Bundle.main.bundleURL
        guard action == "status" || bundleURL.pathExtension == "app" else {
            fail("Run the executable inside the installed Codex Pace.app to change its login item.")
        }
        let service = SMAppService.mainApp
        do {
            if action == "enable", service.status != .enabled {
                try service.register()
            } else if action == "disable", service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            printLoginItemStatus(service.status, bundleURL: bundleURL)
            let error = error as NSError
            fail("Login item action failed: \(error.domain) (\(error.code)): \(error.localizedDescription)")
        }
        let status = service.status
        printLoginItemStatus(status, bundleURL: bundleURL)
        if action == "enable", status != .enabled {
            if status == .requiresApproval {
                fail("Login item requires approval in System Settings → General → Login Items.")
            }
            fail("Login item is not enabled.")
        }
    }

    private static func printLoginItemStatus(_ status: SMAppService.Status, bundleURL: URL) {
        let name: String
        switch status {
        case .enabled: name = "enabled"
        case .requiresApproval: name = "requires-approval"
        case .notRegistered: name = "not-registered"
        case .notFound: name = "not-found"
        @unknown default: name = "unknown"
        }
        print("bundle: \(bundleURL.path)")
        print("launch-at-login: \(name)")
    }

    @MainActor
    private static func renderPreview(to path: String, dark: Bool, details: Bool, scenario: PreviewScenario) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = TrackerModel(isDemo: true, demoScenario: scenario)
        let view = NSHostingView(rootView: TrackerView(model: model, showDetails: details))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.contentView = view
        view.setFrameSize(view.fittingSize)
        window.setContentSize(view.fittingSize)
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fail("Could not render the preview.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fail("Could not encode the preview.")
            }
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fail("Could not write the preview PNG.") }
            print(path)
            app.stop(nil)
            // Wake the application run loop so stop takes effect without another user event.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(event, atStart: true)
            }
        }
        app.run()
        window.close()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
