import Foundation
import os.lock
import Testing
@testable import CodexBar

struct SpendDashboardHourlyDaysTests {
    @Test
    func `construction and equality leave navigation days pending`() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let days = SpendDashboardHourlyDays {
            calls.withLock { $0 += 1 }
            return [Date(timeIntervalSince1970: 0)]
        }
        let other = SpendDashboardHourlyDays { [] }

        #expect(calls.withLock { $0 } == 0)
        #expect(days == other)
        #expect(calls.withLock { $0 } == 0)
        #expect(days.value == [Date(timeIntervalSince1970: 0)])
        #expect(days == other)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `repeated and copied readers reuse one derivation including an empty result`() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let days = SpendDashboardHourlyDays {
            calls.withLock { $0 += 1 }
            return []
        }
        let copy = days
        for _ in 0..<20 {
            #expect(days.value.isEmpty)
            #expect(copy.value.isEmpty)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `concurrent copied readers derive one complete date array`() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let expected = (0..<365).map { Date(timeIntervalSince1970: Double($0) * 86400) }
        let days = SpendDashboardHourlyDays {
            calls.withLock { $0 += 1 }
            return expected
        }
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let copy = days
            #expect(copy.value == expected)
            #expect(copy.value == expected)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `separate groups own separate pending derivations`() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let makeDays: @Sendable () -> [Date] = {
            calls.withLock { $0 += 1 }
            return []
        }
        let first = SpendDashboardHourlyDays(makeDays: makeDays)
        let second = SpendDashboardHourlyDays(makeDays: makeDays)
        #expect(calls.withLock { $0 } == 0)
        #expect(first.value.isEmpty)
        #expect(second.value.isEmpty)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test
    func `resolved dates release history captured by their factory`() {
        final class History: Sendable {
            let days = [Date(timeIntervalSince1970: 0)]
        }
        weak var history: History?
        let days: SpendDashboardHourlyDays
        do {
            let input = History()
            history = input
            days = SpendDashboardHourlyDays { input.days }
        }
        #expect(history != nil)
        #expect(days.value == [Date(timeIntervalSince1970: 0)])
        #expect(history == nil)
    }
}
