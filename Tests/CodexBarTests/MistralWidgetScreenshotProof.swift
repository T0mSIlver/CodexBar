import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarWidget

/// Throwaway proof: renders the real widget tiles from a UsageStore-built snapshot for each Mistral metric.
@MainActor
final class MistralWidgetScreenshotProof: XCTestCase {
    func test_renderMistralWidgetTiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISTRAL_WIDGET_PROOF_DIR"] else {
            throw XCTSkip("Set MISTRAL_WIDGET_PROOF_DIR")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let now = Date()
        let reset = Calendar(identifier: .gregorian).date(byAdding: .day, value: 5, to: now)!
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

        var rows: [(String, WidgetSnapshot.ProviderEntry)] = []
        for (label, preference) in [
            ("Automatic", MenuBarMetricPreference.automatic),
            ("Included API", .primary),
            ("Monthly Plan", .monthlyPlan),
        ] {
            let suite = "MistralWidgetScreenshotProof-\(preference.rawValue)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: testConfigStore(suiteName: suite),
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore())
            settings.statusChecksEnabled = false
            settings.setMenuBarMetricPreference(preference, for: .mistral)
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            store._setSnapshotForTesting(usage, provider: .mistral)
            var saved: WidgetSnapshot?
            store._test_widgetSnapshotSaveOverride = { saved = $0 }
            store.persistWidgetSnapshot(reason: "mistral-widget-proof")
            await store.widgetSnapshotPersistTask?.value
            store._test_widgetSnapshotSaveOverride = nil
            let entry = try XCTUnwrap(saved?.entries.first { $0.provider == .mistral })
            rows.append((label, entry))
        }

        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.0) { label, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu bar metric: \(label)").font(.headline)
                        HStack(alignment: .top, spacing: 18) {
                            Self.tile(entry, size: .small).frame(width: 170, height: 170)
                            Self.tile(entry, size: .medium).frame(width: 364, height: 170)
                        }
                    }
                }
            }
            .padding(20)
            .background(scheme == .dark ? Color.black : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("mistral-widget-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private static func tile(_ entry: WidgetSnapshot.ProviderEntry, size: WidgetTileSize) -> some View {
        CodexBarWidget.UsageTile(entry: entry, size: size) {
            TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: size)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary))
    }
}
