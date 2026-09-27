import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarWidget

/// Throwaway proof: drives the production Mistral settings picker, then renders the widget the choice produces.
@MainActor
final class MistralMonthlyPlanPickerProof: XCTestCase {
    private var pending: (window: NSWindow, popup: NSPopUpButton, output: URL, selection: String)?
    private var capturedOptions: [String] = []
    private var log: [String] = []

    func test_pickMonthlyPlanInSettings() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISTRAL_PICKER_PROOF_DIR"] else {
            throw XCTSkip("Set MISTRAL_PICKER_PROOF_DIR")
        }
        let before = ProcessInfo.processInfo.environment["MISTRAL_PICKER_PROOF_PHASE"] == "before"
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "MistralMonthlyPlanPickerProof"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.menuBarIconStyle = .iconAndPercent
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: .mistral)
        self.log.append("before: metric=\(settings.menuBarMetricPreference(for: .mistral).rawValue)")

        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Settings › Providers › Mistral"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PickerProofView(settings: settings))
        window.contentView = hosting
        defer {
            self.pending?.popup.menu?.cancelTracking()
            window.close()
        }
        for scheme in ["light", "dark"] {
            window.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            if scheme == "dark" {
                settings.setMenuBarMetricPreference(.automatic, for: .mistral)
                settings.setMenuBarLayout(
                    MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: .mistral)
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            self.flush(window)
            try self.snapshot(window, to: output.appendingPathComponent("picker-before-\(scheme).png"))
            let popup = try XCTUnwrap(Self.popup(in: hosting), "Expected the production Picker's native control")
            self.pending = (window, popup, output.appendingPathComponent("picker-open-\(scheme).png"), "Monthly Plan")
            let timer = Timer(
                timeInterval: 1, target: self, selector: #selector(self.captureAndChoose), userInfo: nil,
                repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            popup.performClick(nil)
            timer.invalidate()
            self.pending = nil
            self.flush(window)
            self.log.append("\(scheme) options: \(self.capturedOptions)")
            try self.snapshot(window, to: output.appendingPathComponent("picker-after-\(scheme).png"))
        }
        let metric = settings.menuBarMetricPreference(for: .mistral)
        self.log.append("after: metric=\(metric.rawValue) layout=\(settings.menuBarLayout(for: .mistral).lines)")

        let entry = try await Self.widgetEntry(settings: settings)
        self.log.append("widget rows: \(entry.usageRows?.map(\.title) ?? [])")
        for scheme in [ColorScheme.light, .dark] {
            let sheet = HStack(alignment: .top, spacing: 18) {
                Self.tile(entry, size: .small).frame(width: 170, height: 170)
                Self.tile(entry, size: .medium).frame(width: 364, height: 170)
            }
            .padding(20)
            .background(scheme == .dark ? Color.black : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("widget-\(scheme == .dark ? "dark" : "light").png"))
        }
        try self.log.joined(separator: "\n").write(
            to: output.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(self.capturedOptions.contains("Monthly Plan"), !before)
        XCTAssertEqual(metric == .monthlyPlan, !before)
        XCTAssertEqual(entry.usageRows?.map(\.title), before ? ["Included API"] : ["Monthly Plan"])
    }

    @objc private func captureAndChoose() {
        guard let pending = self.pending else { return }
        defer { pending.popup.menu?.cancelTracking() }
        self.capturedOptions = pending.popup.itemTitles
        self.screencapture(pending.window, to: pending.output)
        if let menu = pending.popup.menu,
           let index = menu.items.firstIndex(where: { $0.title == pending.selection })
        {
            pending.popup.selectItem(at: index)
            menu.performActionForItem(at: index)
        }
    }

    /// Screen capture includes the open menu; a failure is logged, not fatal, because the runner may deny it.
    private func screencapture(_ window: NSWindow, to output: URL) {
        guard let screen = NSScreen.screens.first else { return self.log.append("screencapture: no screen") }
        let frame = window.frame.insetBy(dx: -20, dy: -160)
        let rectangle = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", rectangle, output.path]
        do {
            try process.run()
            process.waitUntilExit()
            self.log.append("screencapture \(output.lastPathComponent): status \(process.terminationStatus)")
        } catch {
            self.log.append("screencapture \(output.lastPathComponent): \(error)")
        }
    }

    private func snapshot(_ window: NSWindow, to output: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output)
    }

    private func flush(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    private static func popup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        return view.subviews.lazy.compactMap { Self.popup(in: $0) }.first
    }

    private static func widgetEntry(settings: SettingsStore) async throws -> WidgetSnapshot.ProviderEntry {
        let now = Date()
        let reset = Calendar(identifier: .gregorian).date(byAdding: .day, value: 4, to: now)!
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 75.2,
                windowMinutes: nil,
                resetsAt: reset,
                resetDescription: "€19.17 / €25.50 · €6.33 left"),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(
                        usedPercent: 21.1,
                        windowMinutes: nil,
                        resetsAt: reset,
                        resetDescription: "€53.89 / €255.00 · €201.11 left")),
            ],
            updatedAt: now)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(usage, provider: .mistral)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        store.persistWidgetSnapshot(reason: "mistral-picker-proof")
        await store.widgetSnapshotPersistTask?.value
        store._test_widgetSnapshotSaveOverride = nil
        return try XCTUnwrap(saved?.entries.first { $0.provider == .mistral })
    }

    private static func tile(_ entry: WidgetSnapshot.ProviderEntry, size: WidgetTileSize) -> some View {
        CodexBarWidget.UsageTile(entry: entry, size: size) {
            TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: size)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary))
    }
}

@MainActor
private struct PickerProofView: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            ProviderMenuBarPercentWindowSettingsView(provider: .mistral, settings: self.settings)
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: "en"))
        .frame(width: 560, height: 200)
    }
}
