import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendTrendHourlyDaysTests {
    @Test
    func `navigation reads preserve snapshot equality across independent groups and copies`() throws {
        let start = try Self.date("2026-10-01T00:00:00Z")
        let points = [Self.point(start)]
        let first = Self.group(points: points, bounds: start...start.addingTimeInterval(86400))
        let sameInputs = Self.group(points: points, bounds: start...start.addingTimeInterval(86400))
        let copy = first
        #expect(first == sameInputs)
        #expect(SpendTrendChartModel.hourlyDays(first) == [start])
        #expect(first == sameInputs)
        #expect(copy == sameInputs)
        #expect(SpendTrendChartModel.hourlyDays(copy) == [start])
        #expect(SpendTrendChartModel.hourlyDays(sameInputs) == [start])
        #expect(first == sameInputs)
        #expect(first != Self.group(points: [], bounds: start...start.addingTimeInterval(86400)))
    }

    @Test
    func `empty hourly history has no navigable or focused day`() throws {
        let start = try Self.date("2026-10-01T00:00:00Z")
        let group = Self.group(points: [], bounds: start...start.addingTimeInterval(86400), selectedDay: start)
        #expect(SpendTrendChartModel.hourlyDays(group).isEmpty)
        #expect(SpendTrendChartModel.focusedDay(start, group: group) == nil)
    }

    @Test
    func `navigation sorts distinct recorded days within the half open reporting range`() throws {
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let end = second.addingTimeInterval(86400)
        let group = Self.group(
            points: [
                Self.point(second.addingTimeInterval(3600)),
                Self.point(end),
                Self.point(first, sourceID: "demo-b", cost: 0),
                Self.point(first.addingTimeInterval(-1)),
                Self.point(second.addingTimeInterval(7200), sourceID: "demo-b"),
                Self.point(first.addingTimeInterval(3600)),
            ],
            bounds: first...end,
            selectedDay: first)

        #expect(SpendTrendChartModel.hourlyDays(group) == [first, second])
        #expect(SpendTrendChartModel.focusedDay(nil, group: group) == first)
        #expect(SpendTrendChartModel.focusedDay(end, group: Self.group(
            points: group.hourlyPoints, bounds: first...end)) == second)
    }

    @Test(arguments: [
        ("America/Los_Angeles", 2026, 3, 8, 23.0),
        ("America/Los_Angeles", 2026, 11, 1, 25.0),
        ("Australia/Lord_Howe", 2026, 4, 5, 24.5),
        ("Australia/Lord_Howe", 2026, 10, 4, 23.5),
        ("America/Sao_Paulo", 2018, 11, 4, 23.0),
    ])
    func `navigation retains one date across daylight saving transitions`(
        zone: String, year: Int, month: Int, day: Int, hours: Double) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let noon = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        let start = calendar.startOfDay(for: noon)
        let end = try calendar.startOfDay(for: #require(calendar.date(byAdding: .day, value: 1, to: noon)))
        #expect(end.timeIntervalSince(start) == hours * 3600)
        let group = Self.group(
            points: [Self.point(start), Self.point(end.addingTimeInterval(-1800)), Self.point(end)],
            bounds: start...end,
            timeZone: calendar.timeZone)

        #expect(SpendTrendChartModel.hourlyDays(group) == [start])
        #expect(SpendTrendChartModel.focusedDay(nil, group: group) == start)
    }

    @Test
    func `a new time zone derives new dates from the same instants`() throws {
        let bounds = try Self.date("2026-10-01T00:00:00Z")...Self.date("2026-10-04T00:00:00Z")
        let points = try ["2026-10-02T00:30:00Z", "2026-10-02T07:30:00Z"].map {
            try Self.point(Self.date($0))
        }
        let pacific = try Self.group(
            points: points, bounds: bounds, timeZone: #require(TimeZone(identifier: "America/Los_Angeles")))
        let shanghai = try Self.group(
            points: points, bounds: bounds, timeZone: #require(TimeZone(identifier: "Asia/Shanghai")))

        #expect(try SpendTrendChartModel.hourlyDays(pacific) == [
            Self.date("2026-10-01T07:00:00Z"), Self.date("2026-10-02T07:00:00Z"),
        ])
        #expect(try SpendTrendChartModel.hourlyDays(shanghai) == [Self.date("2026-10-01T16:00:00Z")])
        #expect(SpendTrendChartModel.hourlyDays(pacific).count == 2)
    }

    @Test
    func `rebuilt models follow range selection hidden sources and replaced account history`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let third = second.addingTimeInterval(86400)
        let now = third.addingTimeInterval(12 * 3600)
        let a = Self.input(id: "demo-a", day: "2026-10-01", hour: first.addingTimeInterval(3600), now: now)
        let b = Self.input(id: "demo-b", day: "2026-10-03", hour: third.addingTimeInterval(3600), now: now)
        func build(
            inputs: [SpendDashboardModel.ProviderInput] = [a, b],
            period: CostReportingPeriod = .allTime,
            hidden: Set<String> = [],
            selectedDay: Date? = nil) throws -> SpendDashboardModel.CurrencyGroup
        {
            try #require(SpendDashboardModel.build(
                inputs: inputs,
                reportingPeriod: period,
                now: now,
                calendar: calendar,
                hiddenSourceIDs: hidden,
                selectedDay: selectedDay).groups.first)
        }
        let original = try build()
        #expect(SpendTrendChartModel.hourlyDays(original) == [first, third])
        #expect(try SpendTrendChartModel.hourlyDays(build(period: .rolling(days: 1))) == [third])
        #expect(try SpendTrendChartModel.hourlyDays(build(hidden: [b.id])) == [first])
        #expect(try SpendTrendChartModel.hourlyDays(build(selectedDay: third)) == [third])
        #expect(try SpendTrendChartModel.hourlyDays(build(selectedDay: second)).isEmpty)
        let replacement = Self.input(id: a.id, day: "2026-10-02", hour: second.addingTimeInterval(3600), now: now)
        #expect(try SpendTrendChartModel.hourlyDays(build(inputs: [replacement])) == [second])
        #expect(try SpendTrendChartModel.hourlyDays(build()) == [first, third])
        #expect(SpendTrendChartModel.hourlyDays(original) == [first, third])
    }

    @Test
    func `partial history keeps recorded zero hours without inventing dates for unpriced hours`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let first = try Self.date("2026-10-01T00:00:00Z")
        let second = first.addingTimeInterval(86400)
        let now = second.addingTimeInterval(12 * 3600)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [Self.entry("2026-10-01", cost: 0), Self.entry("2026-10-02", cost: nil)],
            hourly: [
                CostUsageHourlyEntry(hour: first.addingTimeInterval(3600), totalTokens: nil, costUSD: 0),
                CostUsageHourlyEntry(hour: second.addingTimeInterval(3600), totalTokens: nil, costUSD: nil),
            ],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(id: "demo-partial", provider: .codex, displayName: "Demo account", snapshot: snapshot)],
            reportingPeriod: .allTime,
            now: now,
            calendar: calendar).groups.first)

        #expect(group.totalCost == nil)
        #expect(group.hourlyPoints.map(\.cost) == [0])
        #expect(SpendTrendChartModel.hourlyDays(group) == [first])
        #expect(SpendTrendChartModel.focusedDay(second, group: group) == first)
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private static func point(
        _ hour: Date, sourceID: String = "demo-a", cost: Double = 1) -> SpendDashboardModel.HourlyPoint
    {
        SpendDashboardModel.HourlyPoint(
            sourceID: sourceID,
            provider: .codex,
            providerName: "Demo account",
            hour: hour,
            cost: cost,
            stackStart: 0,
            stackEnd: cost)
    }

    private static func group(
        points: [SpendDashboardModel.HourlyPoint],
        bounds: ClosedRange<Date>,
        selectedDay: Date? = nil,
        timeZone: TimeZone = .gmt) -> SpendDashboardModel.CurrencyGroup
    {
        SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [],
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 0,
            chartDomain: bounds,
            modelHistoryCompleteness: .incomplete,
            selectedDay: selectedDay,
            hourlyPoints: points,
            timeZone: timeZone)
    }

    private static func input(
        id: String, day: String, hour: Date, now: Date) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: .codex,
            displayName: "Demo account",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [self.entry(day, cost: 1)],
                hourly: [CostUsageHourlyEntry(hour: hour, totalTokens: nil, costUSD: 1)],
                updatedAt: now))
    }

    private static func entry(_ day: String, cost: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}
