import AppKit
import Combine
import CodexUsage
import Foundation
import QuotaCore
import ServiceManagement

@MainActor
final class TrackerModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var changes: [QuotaChange] = []
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            if !isDemo { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
        }
    }
    @Published var selectedWindowID = "" {
        didSet {
            if !isDemo { defaults.set(selectedWindowID, forKey: "selectedWindowID") }
        }
    }

    private let defaults: UserDefaults
    private let isDemo: Bool
    private var executableOverride: URL?
    private var refreshTimer: Timer?
    private var activeFetch: Task<UsageSnapshot, Error>?
    private var consecutiveFailures = 0
    private var suspended = false
    private var stopping = false
    private let refreshInterval: TimeInterval = 300

    var cliPath: String? {
        try? CodexExecutable.resolve(overridePath: executableOverride?.path).path
    }

    var selectedWindow: QuotaWindow? {
        snapshot?.windows.first(where: { $0.id == selectedWindowID }) ?? snapshot?.preferredWindow
    }

    var isStale: Bool {
        isStale(at: Date())
    }

    func isStale(at now: Date) -> Bool {
        guard let snapshot else { return true }
        return errorMessage != nil
            || now.timeIntervalSince(snapshot.fetchedAt) > refreshInterval + 60
            || selectedWindow?.resetsAt.map { $0 <= now } == true
    }

    init(isDemo: Bool = false, cliPath: String? = nil, defaults: UserDefaults = .standard, demoScenario: PreviewScenario = .ahead) {
        self.isDemo = isDemo
        self.defaults = defaults
        menuBarDisplayMode = MenuBarDisplayMode(preference: defaults.string(forKey: "menuBarDisplayMode"))
        if let path = cliPath ?? defaults.string(forKey: "codexExecutablePath"), !path.isEmpty {
            executableOverride = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        selectedWindowID = defaults.string(forKey: "selectedWindowID") ?? ""
        if isDemo {
            let now = Date()
            snapshot = demoScenario.snapshot(at: now)
            selectedWindowID = snapshot?.preferredWindow?.id ?? ""
            errorMessage = demoScenario.errorMessage
            changes = demoScenario.changes(at: now)
            nextRefreshAt = now.addingTimeInterval(refreshInterval)
        } else {
            restoreCache()
            if snapshot?.windows.contains(where: { $0.id == selectedWindowID }) != true {
                selectedWindowID = snapshot?.preferredWindow?.id ?? ""
            }
        }
        updateLoginItemStatus()
    }

    func start() {
        guard !isDemo else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing, !suspended, !stopping else { return }
        guard !isDemo else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextRefreshAt = nil
        isRefreshing = true

        let client = CodexUsageClient(executableURL: executableOverride)
        let task = Task { try await client.fetch() }
        activeFetch = task
        do {
            let fresh = try await task.value
            guard !stopping, !suspended else {
                activeFetch = nil
                isRefreshing = false
                return
            }
            let detected = QuotaChangeDetector.changes(from: snapshot, to: fresh)
            // Always use the new server values, even when usage rises or a reset moves backwards.
            changes = Array((detected + changes).prefix(12))
            snapshot = fresh
            if !fresh.windows.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = fresh.preferredWindow?.id ?? ""
            }
            errorMessage = nil
            consecutiveFailures = 0
            saveCache()
        } catch is CancellationError {
            // Sleeping, quitting, or changing the CLI is not a failed usage read.
        } catch {
            if !stopping, !suspended {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Usage could not be refreshed. Try again."
                consecutiveFailures += 1
            }
        }
        activeFetch = nil
        isRefreshing = false
        if !suspended, !stopping { scheduleNextRefresh() }
    }

    func suspend() {
        suspended = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextRefreshAt = nil
        activeFetch?.cancel()
    }

    func resume() {
        suspended = false
        Task {
            await waitForActiveRefresh()
            await refresh()
        }
    }

    func stop() async {
        stopping = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextRefreshAt = nil
        activeFetch?.cancel()
        if let activeFetch { _ = try? await activeFetch.value }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func openUsageDashboard() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex executable"
        panel.message = "Select the codex CLI you already use with your ChatGPT account."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            errorMessage = "That file is not executable. Choose the codex command-line executable."
            return
        }
        executableOverride = url
        defaults.set(url.path, forKey: "codexExecutablePath")
        activeFetch?.cancel()
        Task {
            await waitForActiveRefresh()
            await refresh()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLoginMessage = "Launch the built Codex Pace.app to enable opening at login."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLoginItemStatus()
        } catch {
            launchAtLoginMessage = "Could not change the login item. Check System Settings → General → Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func updateLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginMessage = nil
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginMessage = "Allow Codex Pace in System Settings → General → Login Items."
        default:
            launchAtLogin = false
            launchAtLoginMessage = nil
        }
    }

    private func scheduleNextRefresh() {
        let now = Date()
        let next = RefreshSchedule.nextRefresh(
            after: now, snapshot: snapshot, consecutiveFailures: consecutiveFailures,
            jitterFraction: Double.random(in: 0...0.05)
        )
        let delay = next.timeIntervalSince(now)
        nextRefreshAt = next
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = min(5, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func waitForActiveRefresh() async {
        // The caller that owns refresh() also updates its UI state after helper cleanup.
        if let activeFetch { _ = try? await activeFetch.value }
        while isRefreshing { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private struct CachedState: Codable {
        let version: Int
        let snapshot: UsageSnapshot
        let changes: [QuotaChange]
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CodexPace", isDirectory: true).appendingPathComponent("usage.json")
    }

    private func restoreCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedState.self, from: data), cached.version == 1 else { return }
        snapshot = cached.snapshot
        changes = Array(cached.changes.prefix(12))
    }

    private func saveCache() {
        guard !isDemo, let snapshot else { return }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(CachedState(version: 1, snapshot: snapshot, changes: changes))
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            // A cache failure must not hide a successful live usage reading.
        }
    }
}
