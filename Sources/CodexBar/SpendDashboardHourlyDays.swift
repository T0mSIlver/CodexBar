import Foundation
import os.lock

/// Memoization belongs to one immutable currency group, including its value copies.
/// Summary-only callers never evaluate the factory. Concurrent chart readers evaluate it once.
struct SpendDashboardHourlyDays: Equatable, Sendable {
    private enum State: Sendable {
        case pending(@Sendable () -> [Date])
        case ready([Date])
    }

    private let state: OSAllocatedUnfairLock<State>

    init(makeDays: @escaping @Sendable () -> [Date]) {
        self.state = OSAllocatedUnfairLock(initialState: .pending(makeDays))
    }

    var value: [Date] {
        self.state.withLock { state in
            switch state {
            case let .ready(days):
                return days
            case let .pending(makeDays):
                let days = makeDays()
                // Release the factory's captured history after deriving the dates.
                state = .ready(days)
                return days
            }
        }
    }

    static func == (_: Self, _: Self) -> Bool {
        // CurrencyGroup compares all immutable inputs; memoization state is not model data.
        // Reading the chart must not change snapshot equality or evaluate a pending factory.
        true
    }
}
