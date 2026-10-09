---
summary: "Synthetic full Settings Release A/B evidence for reusing hourly navigation dates."
read_when:
  - Reviewing spend trend date navigation performance
---

# Hourly navigation date reuse

`CurrencyGroup` is immutable. Its hourly points, reporting range and time zone determine the
available navigation dates. Computing these dates once lets view evaluations and previous/next
day navigation reuse the result. A new group derives its own dates when the data, range or zone
changes. The production change uses the same normalization, half-open range and sorting as before.

## Full Settings experiment

The baseline is `b0aa7fe0add90b06e3614328715d827f1c898a0f`. A complete **Release (-O)** diagnostic
application displays the production `SettingsWindowController`, `PreferencesView` and
`SpendDashboardPane` with injected synthetic data. The shipping date-list body is retained;
the prototype switch moves that same computation to immutable group creation. The production
patch makes that reuse unconditional and removes the diagnostic switch from the shipping path.

Four sources contain 365 days, **35,020 hourly points** and 1,460 daily points. The current day
contains 19 hours; earlier days contain 24. Cursor also has 10,000 synthetic sessions, with the
initial session rows bounded at 50. Names, dates, amounts and history are fixtures, not user data.
All four controlled runs use the same executable and fixture; their SHA-256 hashes are recorded
in [the receipt](build-receipt.json) and [measurements](measurements.json).

The order is baseline A1, cached B1, cached B2, baseline A2, each in a fresh process. Each run
uses the native **Hour**, **Previous day**, **Previous day** buttons. Accessibility inspection
confirms October 5, 4 and 3 and 19, 24 and 24 hourly bars. A checkpoint bounds each operation.
The date-list calls do not rebuild the account model.

| Operation | Calls per operation | Baseline main-thread CPU, A1 / A2 | Cached, B1 / B2 |
| --- | ---: | ---: | ---: |
| Overview to Hour | 14 | 291.97 / 309.28 ms | both <0.01 ms |
| Previous day | 15 | 309.11 / 317.65 ms | both <0.01 ms |
| Previous day again | 15 | 308.84 / 310.93 ms | both <0.01 ms |

Timers use `CLOCK_THREAD_CPUTIME_ID` and `CLOCK_UPTIME_RAW`, with sample recording after the
measured body. Every recorded date-list call is on the main thread. The tiny cached durations
are close to clock resolution; no large speedup ratio is claimed. View counts are retained,
including differing chart-body counts during the mode change, rather than treating them as equal.

Precomputation has a cost: initial model rebuild CPU is **62.28 / 63.21 ms** in baseline runs and
**89.20 / 82.04 ms** in cached runs. It moves the initial work; it saves repeated later work.
The durations above cover date-list computation, not click-to-paint time, frame rate, hitch counts,
total application CPU or energy. The fixture size is not evidence of any particular user's history.

Before the controlled experiment, a separate 30-day fixture with 2,860 hourly points reproduced
14–15 date-list calls per native operation and 26.72–38.54 ms of cumulative CPU. Those observations
are not mixed into the controlled A/B table.

## Compatibility

The programmatic context matrix is separate from native UI timing. The
[baseline](compatibility-baseline.json) and [cached](compatibility-cached.json) records contain
complete date arrays, range boundaries, hourly counts and synthetic totals for 11 matching contexts:
Shanghai, UTC, New York and Lord Howe; all history, 30 days, 7 days and month to date; selected day,
clear selection and restoration of all history. Arrays and totals match across modes, and each
record checks the original algorithm and focused-day fallback. This matrix is not a claim of full
product regression coverage. The new production tests additionally cover empty/partial histories,
recorded zero, range boundaries, source hiding, replacement history and daylight-saving changes.

## Reproduce

The [instrumentation](instrumentation.patch), [prototype](prototype.patch), fixture and timing
helper live here as documentation; SwiftPM does not compile them into the shipping application.
From the repository root on macOS with the project's Swift toolchain:

```sh
python3 docs/proof/spend-hourly-days/reproduce.py build
python3 docs/proof/spend-hourly-days/reproduce.py run baseline-a1
```

The build uses a fresh ignored source archive of the pinned baseline. The run uses dictionary
defaults, temporary configuration, a synthetic home, a testing loader, disabled Keychain access
and a sandbox that denies outbound network and personal-home access outside the proof directory.
It displays its own diagnostic Settings window. Production Dock-promotion callbacks are stubbed
because the fixture already runs as a foreground app; this does not measure normal app startup.
The command-polling timer uses non-generic `sleep(nanoseconds:)` after an excluded launch-only
failure with the original generic timer. Neither adaptation changes a measured computation.

After loading settles, record `before-native` below. Click **Hour**, wait for the date and bars
to settle, and record `native-hour-mode`. Click **Previous day**, record `native-previous-day`,
then click it again and record `native-previous-day-repeat`.

```sh
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 checkpoint before-native
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 checkpoint native-hour-mode
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 checkpoint native-previous-day
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 checkpoint native-previous-day-repeat
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 verify
python3 docs/proof/spend-hourly-days/reproduce.py send baseline-a1 finish
```

Repeat with `run cached-b1 --cached`, `run cached-b2 --cached`, then `run baseline-a2`.
The per-run `runtime.json` contains checkpoint deltas; `compatibility.json` contains reference
checks. For context changes, `send RUN time-zone UTC`, `send RUN period rolling:30` and
`send RUN day last` / `send RUN day none` use the diagnostic model interface; wait until
`refreshing` is false, then issue `verify`. These are model-interface checks, not native clicks.
Use the same settling interval and native actions for both modes and keep context changes
outside the measured navigation sequence. Host load and hardware can change elapsed times.

Raw personal traces, process environments and installed-app samples are excluded from this proof.
