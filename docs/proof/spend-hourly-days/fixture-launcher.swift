import AppKit
import CodexBarCore
import Foundation
import SwiftUI

/// Non-shipping fixture launcher. The window, sidebar, pane and shared controller are production code.
@MainActor
enum SpendDashboardAppProof {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["CODEXBAR_DIAGNOSTIC_OUTPUT"] != nil else { return true }
        KeychainAccessGate.isDisabled = true
        for key in ["SWIFT_TESTING", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS",
                    "CODEXBAR_TEST_CODEX_FILE_ISOLATION", "CODEXBAR_TEST_SESSION_FILE_ISOLATION"] {
            setenv(key, "1", 1)
        }
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private var controller: SettingsWindowController?
        private var settings: SettingsStore?
        private var store: UsageStore?

        func applicationDidFinishLaunching(_ notification: Notification) {
            do {
                let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "codexbar-synthetic-settings-proof-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
                let defaults = ProofUserDefaults(values: [
                    "tokenCostUsageEnabled": true,
                    "debugDisableKeychainAccess": true,
                    "appLanguage": "en",
                    "settingsSpendDashboardPeriod": "all",
                    "costUsageBucketTimeZoneIdentifier": "Asia/Shanghai",
                ])
                let settings = SettingsStore(
                    userDefaults: defaults,
                    configStore: CodexBarConfigStore(fileURL: fixtureRoot.appendingPathComponent("config.json")),
                    tokenAccountStore: ProofTokenAccountStore(),
                    antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                        fileURL: fixtureRoot.appendingPathComponent("antigravity.json")),
                    keychainAccessPolicy: SettingsStoreKeychainAccessPolicy(
                        setDisabled: { _ in }, isExplicitlyDisabled: { true }),
                    performInitialProviderDetection: false)
                // Discovery is disabled; all provider history below comes exclusively from the fixture loader.
                for provider in UsageProvider.allCases {
                    guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
                    settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .cursor)
                }
                settings.costUsageEnabled = true
                settings.refreshFrequency = .manual
                settings.statusChecksEnabled = false
                settings.openCodexUsageLogsEnabled = false
                let store = UsageStore(
                    fetcher: UsageFetcher(environment: [:]),
                    browserDetection: BrowserDetection(
                        homeDirectory: fixtureRoot.path, fileExists: { _ in false }, directoryContents: { _ in [] }),
                    settings: settings,
                    startupBehavior: .testing,
                    environmentBase: [:])
                let fixtureDays = Int(ProcessInfo.processInfo.environment["CODEXBAR_FIXTURE_DAYS"] ?? "30") ?? 30
                let inputs = try ProofFixtures.inputs(days: fixtureDays, multipleProviders: true)
                for input in inputs where input.provider == .cursor {
                    store.spendDashboardTokenPublicationRevisions[input.provider.instanceID] = 1
                    store.spendDashboardTokenPublications[input.provider.instanceID] = TokenSnapshotPublication(
                        snapshot: input.snapshot, publicationRevision: 1,
                        providerConfigRevision: settings.providerConfigRevision(for: input.provider),
                        scopeSignature: store.spendDashboardTokenSnapshotScopeSignature(for: input.provider),
                        accounting: nil)
                }
                let now = try ProofFixtures.unwrap(ProofFixtures.calendar.date(
                    from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
                let spendController = SpendDashboardController(
                    userDefaults: defaults,
                    requestBuilder: { _ in
                        SpendDashboardLoadRequest(
                            configuration: SpendDashboardSource.configuration(settings: settings, store: store),
                            capturedInputs: inputs,
                            unavailableSourceIDs: [],
                            codexRequests: [],
                            now: now,
                            force: false)
                    },
                    loader: { request in
                        print("SYNTHETIC fixture loader: four sources; no provider, credential or session probes")
                        return SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
                    },
                    nowProvider: { now })
                store.sharedSpendDashboardControllerStorage = spendController
                let selection = PreferencesSelection(userDefaults: defaults)
                let managed = ManagedCodexAccountCoordinator()
                let promotion = CodexAccountPromotionCoordinator(
                    settingsStore: settings, usageStore: store, managedAccountCoordinator: managed)
                // The production window factory and PreferencesView are retained. Dock promotion is
                // outside these measurements; the fixture is already a regular foreground app.
                let controller = SettingsWindowController(
                    selection: selection,
                    makeWindow: {
                        let view = PreferencesView(
                            settings: settings, store: store, cloudSyncState: CloudSyncState(),
                            updater: DisabledUpdaterController(unavailableReason: "Synthetic fixture build"),
                            selection: selection, managedCodexAccountCoordinator: managed,
                            codexAccountPromotionCoordinator: promotion, runProviderLoginFlow: { _ in })
                        let hosting = NSHostingController(rootView: view)
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: SettingsPane.windowWidth, height: SettingsPane.windowHeight),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
                        window.contentViewController = hosting
                        window.title = selection.pane.title
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .visible
                        window.titlebarSeparatorStyle = .none
                        window.isReleasedWhenClosed = false
                        SettingsWindowSizing.enforceMinimumSize(window)
                        return window
                    },
                    prepareToPresent: {}, registerWindow: { _ in },
                    didPresentWindow: { _ in }, presentationFailed: {})
                self.settings = settings
                self.store = store
                self.controller = controller
                let menu = NSMenu()
                let appItem = NSMenuItem()
                let submenu = NSMenu()
                let settingsItem = NSMenuItem(title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",")
                settingsItem.target = self
                submenu.addItem(settingsItem)
                let quit = NSMenuItem(title: "Quit Synthetic Proof", action: #selector(NSApplication.terminate(_:)),
                                      keyEquivalent: "q")
                submenu.addItem(quit)
                appItem.submenu = submenu
                menu.addItem(appItem)
                NSApp.mainMenu = menu
                self.openSettings()
                controller.window?.setContentSize(NSSize(width: 1060, height: 820))
                controller.window?.appearance = NSAppearance(named: .darkAqua)
                controller.window?.center()
                NSApp.activate(ignoringOtherApps: true)
                if let window = controller.window {
                    FullSettingsDiagnostics.start(window: window, settings: settings, controller: spendController)
                }
                print("SYNTHETIC route: SettingsWindowController -> PreferencesView sidebar -> Usage & Spend")
            } catch {
                print("Synthetic proof failed: \(type(of: error))")
                NSApp.terminate(nil)
            }
        }

        @objc private func openSettings() {
            self.controller?.open(pane: .usageSpend)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
@MainActor
enum ProofFixtures {
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderValueNotFound) }
        return value
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }

    static func inputs(days: Int = 30, multipleProviders: Bool = true) throws -> [SpendDashboardModel.ProviderInput] {
        let calendar = self.calendar
        let now = try self.unwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let accounts: [(String, UsageProvider, String)] = [
            ("codex:demo-a", .codex, "Demo Codex A"), ("codex:demo-b", .codex, "Demo Codex B"),
            ("cursor", .cursor, "Cursor"), ("antigravity", .antigravity, "Antigravity"),
        ]
        return try accounts.enumerated().map { source, account in
            var hourly: [CostUsageHourlyEntry] = []
            var daily: [CostUsageDailyReport.Entry] = []
            for offset in -(days - 1)...0 {
                let day = try self.unwrap(calendar.date(byAdding: .day, value: offset, to: today))
                var cost = 0.0
                var tokens = 0
                for hour in 0..<24 where offset < 0 || hour <= 18 {
                    let amount = Double((abs(offset) + hour + source * 3) % 11 + 1) * 0.01
                    cost += amount
                    tokens += 1000
                    hourly.append(CostUsageHourlyEntry(hour: day.addingTimeInterval(Double(hour) * 3600),
                                                       totalTokens: 1000, costUSD: amount))
                }
                daily.append(CostUsageDailyReport.Entry(
                    date: formatter.string(from: day), inputTokens: nil, outputTokens: nil,
                    totalTokens: tokens, costUSD: cost, modelsUsed: nil, modelBreakdowns: nil))
            }
            let sessions: [CostUsageSessionBreakdown] = source == 2 ? (0..<(days == 30 ? 1000 : 10000)).map { index in
                CostUsageSessionBreakdown(sessionID: "synthetic-\(index)",
                    lastActivity: now.addingTimeInterval(-Double(index % days) * 86400),
                    inputTokens: 800, cachedInputTokens: 0, outputTokens: 200, totalTokens: 1000,
                    requestCount: 1, costUSD: 0.01, modelBreakdowns: [])
            } : []
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: nil, sessionCostUSD: nil, last30DaysTokens: days * 24000,
                last30DaysCostUSD: nil, historyDays: days, costProvenance: .listPriceEstimate,
                daily: daily, sessions: sessions, hourly: hourly, updatedAt: now)
            return SpendDashboardModel.ProviderInput(id: account.0, provider: account.1,
                                                       displayName: account.2, snapshot: snapshot)
        }
    }

}

final class ProofUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "ProofUserDefaults-\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        self.lock.withLock { self.values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        self.lock.withLock { self.values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        self.set(nil as Any?, forKey: defaultName)
    }

    override func bool(forKey defaultName: String) -> Bool {
        (self.object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (self.object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override func float(forKey defaultName: String) -> Float {
        (self.object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (self.object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        self.object(forKey: defaultName) as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        self.object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        self.object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        self.object(forKey: defaultName) as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        self.object(forKey: defaultName) as? [String]
    }

    override func url(forKey defaultName: String) -> URL? {
        self.object(forKey: defaultName) as? URL
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        self.set(url as Any?, forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        self.lock.withLock { self.values }
    }
}

final class ProofTokenAccountStore: ProviderTokenAccountStoring, @unchecked Sendable {
    var accounts: [UsageProvider: ProviderTokenAccountData] = [:]
    private let fileURL: URL

    init(fileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "token-accounts-\(UUID().uuidString).json"))
    {
        self.fileURL = fileURL
    }

    func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] {
        self.accounts
    }

    func storeAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) throws {
        self.accounts = accounts
    }

    func ensureFileExists() throws -> URL {
        self.fileURL
    }
}

