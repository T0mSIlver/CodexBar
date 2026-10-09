import AppKit
import CodexBarCore
import Darwin
import Foundation

/// Investigation-only taps, compiled with the complete Release application.
enum FullSettingsDiagnostics {
    static let dateCacheEnabled = ProcessInfo.processInfo.environment["CODEXBAR_DATE_CACHE_PROTOTYPE"] == "1"
    struct Stamp {
        let wall: UInt64
        let cpu: UInt64
    }

    private struct Measurement {
        let wallMS: Double
        let cpuMS: Double
        let main: Bool
        let rows: Int
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var measurements: [String: [Measurement]] = [:]
    private nonisolated(unsafe) static var counts: [String: Int] = [:]
    private nonisolated(unsafe) static var previousCounts: [String: Int] = [:]
    private nonisolated(unsafe) static var previousSizes: [String: Int] = [:]
    private nonisolated(unsafe) static var records: [[String: Any]] = []

    static func begin() -> Stamp {
        Stamp(wall: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
    }

    static func end(_ name: String, _ start: Stamp, rows: Int = 0) {
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let record = Measurement(wallMS: Double(wall - start.wall) / 1_000_000,
                                 cpuMS: Double(cpu - start.cpu) / 1_000_000,
                                 main: Thread.isMainThread, rows: rows)
        self.lock.withLock { self.measurements[name, default: []].append(record) }
    }

    static func count(_ name: String) {
        self.lock.withLock { self.counts[name, default: 0] += 1 }
    }

    @MainActor
    static func start(window: NSWindow, settings: SettingsStore, controller: SpendDashboardController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_DIAGNOSTIC_OUTPUT"]!)
        self.checkpoint("window-presented", root: root, window: window, settings: settings, controller: controller)
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let commandURL = root.appendingPathComponent("command.json")
                guard let data = try? Data(contentsOf: commandURL),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let action = command["action"] else { continue }
                try? FileManager.default.removeItem(at: commandURL)
                switch action {
                case "verify":
                    self.verify(root: root, controller: controller)
                case "checkpoint":
                    self.checkpoint(command["name"] ?? "checkpoint", root: root, window: window,
                                    settings: settings, controller: controller)
                case "period":
                    controller.selectPeriod(CostReportingPeriod(rawValue: command["value"] ?? "") ?? .allTime)
                case "day":
                    controller.selectDay(command["value"] == "none" ? nil : controller.model.groups.first?.dailyPoints.last?.day)
                case "time-zone":
                    settings.costUsageBucketTimeZoneIdentifier = command["value"] ?? "UTC"
                case "resize":
                    window.setContentSize(NSSize(width: Double(command["value"] ?? "") ?? 1000, height: 820))
                case "scroll":
                    if let scroll = self.scrollViews(in: window.contentView).first(where: {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height
                    }) {
                        scroll.documentView?.scroll(NSPoint(x: 0, y: Double(command["value"] ?? "") ?? 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                case "finish":
                    self.checkpoint(command["name"] ?? "finished", root: root, window: window,
                                    settings: settings, controller: controller)
                    controller.stop()
                    settings.configFileWatcher?.stop()
                    NSApp.terminate(nil)
                default:
                    self.count("unknown-command")
                }
                if let id = command["id"] {
                    try? id.write(to: root.appendingPathComponent("ack.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    @MainActor
    private static func verify(root: URL, controller: SpendDashboardController) {
        let url = root.appendingPathComponent("compatibility.json")
        var records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]) ?? []
        for group in controller.model.groups {
            let reference = Set(group.hourlyPoints.filter {
                $0.hour >= group.chartDomain.lowerBound && $0.hour < group.chartDomain.upperBound
            }.map { group.calendar.startOfDay(for: $0.hour) }).sorted()
            let actual = SpendTrendChartModel.hourlyDays(group)
            let expectedFocus = SpendTrendChartModel.focusedDay(nil, group: group)
            let referenceFocus = [group.selectedDay].compactMap { $0.map { group.calendar.startOfDay(for: $0) } }
                .first(where: reference.contains) ?? reference.last
            records.append([
                "cache_enabled": self.dateCacheEnabled,
                "period": controller.selectedPeriod.rawValue, "zone": group.timeZone.identifier,
                "hourly_points": group.hourlyPoints.count, "day_count": actual.count,
                "dates_match": actual == reference, "focused_day_matches": expectedFocus == referenceFocus,
                "total_cost": group.totalCost.map { $0 as Any } ?? NSNull(),
                "dates_epoch": actual.map(\.timeIntervalSince1970),
                "domain_epoch": [group.chartDomain.lowerBound.timeIntervalSince1970, group.chartDomain.upperBound.timeIntervalSince1970],
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    private static func checkpoint(_ name: String, root: URL, window: NSWindow,
                                   settings: SettingsStore, controller: SpendDashboardController) {
        let groups = controller.model.groups.map {
            ["providers": $0.providers.count, "daily_points": $0.dailyPoints.count,
             "hourly_points": $0.hourlyPoints.count, "sessions": $0.sessions.count,
             "total_tokens": $0.totalTokens.map { $0 as Any } ?? NSNull(),
             "total_cost": $0.totalCost.map { $0 as Any } ?? NSNull()] as [String: Any]
        }
        let scrolls = self.scrollViews(in: window.contentView).filter {
            ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height
        }.map {
            ["offset_y": Double($0.contentView.bounds.minY), "height": Double($0.documentView?.bounds.height ?? 0),
             "viewport": Double($0.contentSize.height)]
        }
        self.lock.withLock {
            var delta: [String: Any] = [:]
            for (key, value) in self.measurements {
                let new = Array(value.dropFirst(self.previousSizes[key, default: 0]))
                delta[key] = self.summary(new)
                self.previousSizes[key] = value.count
            }
            let countDelta = self.counts.map { ($0.key, $0.value - self.previousCounts[$0.key, default: 0]) }
            self.previousCounts = self.counts
            self.records.append([
                "checkpoint": name, "uptime_seconds": ProcessInfo.processInfo.systemUptime,
                "measurements_delta": delta, "counts_delta": Dictionary(uniqueKeysWithValues: countDelta),
                "counts_total": self.counts, "groups": groups, "scroll": scrolls,
                "requested_days": controller.model.requestedDays, "selected_period": controller.selectedPeriod.rawValue,
                "selected_day": controller.selectedDay.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
                "zone": settings.costUsageBucketTimeZoneIdentifier, "refreshing": controller.isRefreshing,
                "width": window.contentLayoutRect.width, "visible": window.isVisible,
                "synthetic_only": true,
            ])
            if let data = try? JSONSerialization.data(withJSONObject: self.records, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("runtime.json"), options: .atomic)
            }
        }
    }

    private static func summary(_ values: [Measurement]) -> [String: Any] {
        func percentile(_ list: [Double], _ p: Double) -> Double {
            let sorted = list.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let wall = values.map(\.wallMS)
        let cpu = values.map(\.cpuMS)
        return ["calls": values.count, "main_thread_calls": values.filter(\.main).count,
                "rows_min": values.map(\.rows).min() ?? 0, "rows_max": values.map(\.rows).max() ?? 0,
                "wall_sum_ms": wall.reduce(0, +), "cpu_sum_ms": cpu.reduce(0, +),
                "wall_p50_ms": percentile(wall, 0.5), "wall_p95_ms": percentile(wall, 0.95),
                "wall_max_ms": wall.max() ?? 0, "cpu_p50_ms": percentile(cpu, 0.5),
                "cpu_p95_ms": percentile(cpu, 0.95), "cpu_max_ms": cpu.max() ?? 0]
    }

    @MainActor
    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { self.scrollViews(in: $0) }
    }
}
