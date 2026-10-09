import CodexBarCore
import Darwin
import Foundation
import os.lock

enum HourlyDaysProbe {
    private static let derivations = OSAllocatedUnfairLock(initialState: 0)

    static func didDerive() {
        self.derivations.withLock { $0 += 1 }
    }

    static var count: Int {
        self.derivations.withLock { $0 }
    }
}

@main
enum HourlyDaysModelProof {
    struct Measurement: Codable {
        let operation: String
        let threadCPUMilliseconds: Double
        let wallMilliseconds: Double
        let dateDerivations: Int
    }

    struct GroupRecord: Codable {
        let currency: String
        let hourlyPoints: Int
        let bounds: [Double]
        let dates: [Double]
        let focusedDay: Double?
        let totalCost: Double?
        let totalTokens: Int?
    }

    struct ContextRecord: Codable {
        let name: String
        let groups: [GroupRecord]
        let summary: [String]
    }

    struct Result: Codable {
        let mode: String
        let hourlyPoints: Int
        let measurements: [Measurement]
        let navigationDates: [Double]
        let contexts: [ContextRecord]
    }

    @MainActor
    static func main() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            precondition(Thread.isMainThread)
            let inputs = try ProofFixtures.inputs(days: 365)
            let calendar = ProofFixtures.calendar
            let now = try ProofFixtures.unwrap(calendar.date(from:
                DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
            func build(
                inputs: [SpendDashboardModel.ProviderInput] = inputs,
                period: CostReportingPeriod = .allTime,
                calendar: Calendar = calendar,
                hidden: Set<String> = [],
                selected: Date? = nil) -> SpendDashboardModel
            {
                SpendDashboardModel.build(
                    inputs: inputs,
                    reportingPeriod: period,
                    now: now,
                    calendar: calendar,
                    hiddenSourceIDs: hidden,
                    selectedDay: selected)
            }
            var measurements: [Measurement] = []
            let (model, first) = self.measure("summary-model-and-summary-first") {
                let model = build()
                let summary = OverviewSpendSummary(model: model, providerCount: 4)
                precondition(!summary.primarySpendText.isEmpty)
                return model
            }
            measurements.append(first)
            let (_, repeated) = self.measure("summary-model-and-summary-ten-rebuilds") {
                var count = 0
                for _ in 0..<10 {
                    let summary = OverviewSpendSummary(model: build(), providerCount: 4)
                    count += summary.primarySpendText.count
                }
                precondition(count > 0)
            }
            measurements.append(repeated)
            let group = try ProofFixtures.unwrap(model.groups.first)
            precondition(group.hourlyPoints.count == 35020)
            var navigationDates: [Double] = []
            for (operation, reads) in [
                ("first-fourteen-date-lookups", 14),
                ("warm-fifteen-date-lookups", 15),
                ("warm-fifteen-date-lookups-again", 15),
            ] {
                let (dates, measurement) = self.measure(operation) {
                    var result: [Date] = []
                    var count = 0
                    for _ in 0..<reads {
                        result = SpendTrendChartModel.hourlyDays(group)
                        count += result.count
                    }
                    precondition(count == reads * 365)
                    return result
                }
                navigationDates = dates.map(\.timeIntervalSince1970)
                measurements.append(measurement)
            }

            var contexts: [ContextRecord] = []
            func record(_ name: String, _ model: SpendDashboardModel) {
                let summary = OverviewSpendSummary(model: model, providerCount: 4)
                contexts.append(ContextRecord(
                    name: name,
                    groups: model.groups.map { group in
                        GroupRecord(
                            currency: group.currencyCode,
                            hourlyPoints: group.hourlyPoints.count,
                            bounds: [
                                group.chartDomain.lowerBound.timeIntervalSince1970,
                                group.chartDomain.upperBound.timeIntervalSince1970,
                            ],
                            dates: SpendTrendChartModel.hourlyDays(group).map(\.timeIntervalSince1970),
                            focusedDay: SpendTrendChartModel.focusedDay(nil, group: group)?.timeIntervalSince1970,
                            totalCost: group.totalCost,
                            totalTokens: group.totalTokens)
                    },
                    summary: [
                        summary.primarySpendText,
                        summary.providerCoverageText,
                        summary.tokenText ?? "",
                        summary.historyCoverageText,
                        summary.pricingCoverageText,
                        summary.provenanceText,
                    ]))
            }
            record("all-shanghai", build())
            for name in ["UTC", "America/New_York", "Australia/Lord_Howe"] {
                var changed = calendar
                changed.timeZone = try ProofFixtures.unwrap(TimeZone(identifier: name))
                record("all-\(name)", build(calendar: changed))
            }
            record("rolling-30", build(period: .rolling(days: 30)))
            record("rolling-7", build(period: .rolling(days: 7)))
            record("month-to-date", build(period: .monthToDate))
            record("selected-last", build(selected: calendar.startOfDay(for: now)))
            record("cleared-selection", build())
            record("hidden-source", build(hidden: [inputs[1].id]))
            record("empty-history", build(inputs: []))

            let result = Result(
                mode: CommandLine.arguments[1],
                hourlyPoints: group.hourlyPoints.count,
                measurements: measurements,
                navigationDates: navigationDates,
                contexts: contexts)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }

    private static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> (T, Measurement) {
        let count = HourlyDaysProbe.count
        let cpu = self.nanoseconds(CLOCK_THREAD_CPUTIME_ID)
        let wall = self.nanoseconds(CLOCK_UPTIME_RAW)
        let result = try body()
        let cpuElapsed = self.nanoseconds(CLOCK_THREAD_CPUTIME_ID) - cpu
        let wallElapsed = self.nanoseconds(CLOCK_UPTIME_RAW) - wall
        return (result, Measurement(
            operation: name,
            threadCPUMilliseconds: Double(cpuElapsed) / 1_000_000,
            wallMilliseconds: Double(wallElapsed) / 1_000_000,
            dateDerivations: HourlyDaysProbe.count - count))
    }

    private static func nanoseconds(_ clock: clockid_t) -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(clock, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
