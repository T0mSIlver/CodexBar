#!/usr/bin/env python3
"""Compile actual spend-model sources at -O, reusing existing Debug core dependencies.

This is a model/component benchmark, not a Release application or native UI measurement.
No window, screenshot or recording is created. Run isolated `swift test` first to build dependencies.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PROOF = Path(__file__).resolve().parent
ROOT = PROOF.parents[2]
OUT = ROOT / ".build" / "hourly-days-headless"
BASE = "b0aa7fe0add90b06e3614328715d827f1c898a0f"
EAGER = "0dfac40f882dd81b3f4e74f74fa781fc33793419"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source(path, ref=None):
    if ref:
        return subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=ROOT).decode()
    return (ROOT / path).read_text()


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    return text[start:end] + "\n"


def compile_modes():
    build = ROOT / ".build" / "arm64-apple-macosx" / "debug"
    description = json.loads((build / "description.json").read_text())
    command = next(v for v in description["swiftCommands"].values()
                   if v["moduleName"] == "CodexBarCore")
    flags = ["-O", "-parse-as-library", "-module-name", "HourlyDaysModelProof",
             "-I", str(build / "Modules")]
    args = command["otherArguments"]
    for i, arg in enumerate(args[:-1]):
        if arg in {"-target", "-swift-version", "-package-name", "-sdk", "-module-cache-path", "-I", "-Xcc"}:
            flags += [arg, args[i + 1]]
    dependencies = {"CodexBarCore"}
    todo = ["CodexBarCore"]
    while todo:
        for target in description["targetDependencyMap"].get(todo.pop(), []):
            if target not in dependencies:
                dependencies.add(target)
                todo.append(target)
    objects = [Path(x) for x in (build / "CodexBarPackageTests.product" / "Objects.LinkFileList")
               .read_text().splitlines() if Path(x).parent.name.removesuffix(".build") in dependencies]
    assert objects and all(x.exists() for x in objects)
    dependency_fingerprint = hashlib.sha256()
    for path in sorted(objects):
        dependency_fingerprint.update(str(path.relative_to(build)).encode())
        dependency_fingerprint.update(path.read_bytes())

    pane = source("Sources/CodexBar/PreferencesSpendDashboardPane.swift")
    summary = source("Sources/CodexBar/StatusItemController+OverviewSpend.swift")
    share = source("Sources/CodexBar/ShareStatsPayload.swift")
    controller = source("Sources/CodexBar/SpendDashboardController.swift")
    support = "import CodexBarCore\nimport Foundation\n"
    support += declaration(pane, "enum SpendDashboardTrendSection:")
    support += declaration(summary, "struct OverviewSpendSummary:")
    support += "enum ShareStatsFormatting {\n" + declaration(share, "static func compactCount(") + "}\n"
    support += "enum SpendDashboardSource {\n" + declaration(controller, "static var scanDays:") + "}\n"
    for name in ["spendDashboardCoverageText", "spendDashboardCoverageChipText",
                 "spendDashboardProvenanceText", "spendDashboardGroupCostText"]:
        support += declaration(pane, f"func {name}(")
    fixtures = "import CodexBarCore\nimport Foundation\n@MainActor\n"
    fixtures += declaration((PROOF / "fixture-launcher.swift").read_text(), "enum ProofFixtures {")
    receipts = {}
    for mode, ref in [("baseline", BASE), ("eager", EAGER), ("lazy", None)]:
        folder = OUT / mode
        folder.mkdir(parents=True, exist_ok=True)
        files = {
            "SpendDashboardModel.swift": source("Sources/CodexBar/SpendDashboardModel.swift", ref),
            "SpendDashboardModel+ModelBreakdown.swift": source(
                "Sources/CodexBar/SpendDashboardModel+ModelBreakdown.swift", ref),
            "SpendTrendChartModel.swift": "import AppKit\nimport CodexBarCore\nimport Foundation\n" + declaration(
                source("Sources/CodexBar/SpendTrendChartModel.swift", ref), "struct SpendTrendChartModel {"),
            "Localization.swift": source("Sources/CodexBar/Localization.swift"),
            "Support.swift": support,
            "Fixtures.swift": fixtures,
            "Runner.swift": (PROOF / "headless-benchmark.swift").read_text(),
            "Resources.swift": (build / "CodexBar.build" / "DerivedSources" /
                                "resource_bundle_accessor.swift").read_text(),
        }
        if mode == "lazy":
            files["SpendDashboardHourlyDays.swift"] = source("Sources/CodexBar/SpendDashboardHourlyDays.swift")
        original_hashes = {name: digest(text.encode()) for name, text in files.items()}
        if mode == "baseline":
            chart = files["SpendTrendChartModel.swift"]
            marker = "static func hourlyDays(_ group: SpendDashboardModel.CurrencyGroup) -> [Date] {\n"
            assert chart.count(marker) == 1
            files["SpendTrendChartModel.swift"] = chart.replace(
                marker, marker + "        HourlyDaysProbe.didDerive()\n        return ", 1)
        else:
            model = files["SpendDashboardModel.swift"]
            marker = "let calendar = SpendDashboardModel.gregorianCalendar(timeZone: timeZone)"
            assert model.count(marker) == 1
            files["SpendDashboardModel.swift"] = model.replace(
                marker, "HourlyDaysProbe.didDerive()\n            " + marker)
        for name, text in files.items():
            (folder / name).write_text(text)
        executable = folder / "HourlyDaysModelTests"
        invocation = ["xcrun", "swiftc", *flags, *(str(folder / name) for name in files),
                      *(str(x) for x in objects), "-o", str(executable)]
        with (folder / "build.log").open("w") as log:
            result = subprocess.run(invocation, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print(f"{mode} compilation failed; see ignored build log", file=sys.stderr)
            return None
        production_paths = ["Sources/CodexBar/SpendDashboardModel.swift",
                            "Sources/CodexBar/SpendDashboardModel+ModelBreakdown.swift",
                            "Sources/CodexBar/SpendTrendChartModel.swift"]
        if mode == "lazy":
            production_paths.append("Sources/CodexBar/SpendDashboardHourlyDays.swift")
        receipts[mode] = {"ref": ref or "working-tree", "original_source_sha256": original_hashes,
                          "production_file_sha256": {path: digest(source(path, ref).encode())
                                                     for path in production_paths},
                          "instrumented_source_sha256": {name: digest(text.encode())
                                                          for name, text in files.items()},
                          "executable_sha256": digest(executable.read_bytes())}
    return {"modes": receipts, "dependency_object_count": len(objects),
            "dependency_object_sha256": dependency_fingerprint.hexdigest(),
            "core_dependency_build": "existing Debug SwiftPM objects",
            "model_optimization": "swiftc -O", "fixture_sha256": digest(
                (PROOF / "fixture-launcher.swift").read_bytes()),
            "driver_sha256": digest(Path(__file__).read_bytes()),
            "helper_sha256": digest((PROOF / "headless-benchmark.swift").read_bytes()),
            "swift_version": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip()}


def run_modes(receipt):
    runs = []
    home = OUT / "synthetic-home"
    home.mkdir(exist_ok=True)
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
                   "LANG": "en_US.UTF-8", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                   "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1", "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
                   "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1"}
    profile = OUT / "isolation.sb"
    quote = lambda value: json.dumps(str(value))
    profile.write_text('(version 1)\n(allow default)\n(deny network*)\n'
                       f'(deny file-read* file-write* (subpath {quote(Path.home())}))\n'
                       f'(allow file-read* (subpath {quote(ROOT / ".build")}))\n'
                       f'(allow file-read* file-write* (subpath {quote(OUT)}))\n')
    for index, mode in enumerate(["baseline", "lazy", "eager", "eager", "lazy", "baseline"]):
        path = OUT / f"run-{index + 1}-{mode}.json"
        with (OUT / f"run-{index + 1}-{mode}.log").open("w") as log:
            subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile),
                            str(OUT / mode / "HourlyDaysModelTests"), mode, str(path)],
                           env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        runs.append(json.loads(path.read_text()))
    expected = runs[0]
    for run in runs:
        assert run["hourlyPoints"] == 35020
        assert run["navigationDates"] == expected["navigationDates"]
        assert run["contexts"] == expected["contexts"]
        counts = [m["dateDerivations"] for m in run["measurements"]]
        if run["mode"] == "baseline":
            assert counts == [0, 0, 14, 15, 15], counts
        elif run["mode"] == "lazy":
            assert counts == [0, 0, 1, 0, 0], counts
        else:
            assert counts[0] > 0 and counts[1] > 0 and counts[2:] == [0, 0, 0], counts
    result = {"scope": "optimized production model/component sources with existing Debug core dependencies",
              "not_measured": ["native menu or chart interaction", "click-to-paint", "frame rate", "energy"],
              "order": [run["mode"] for run in runs], "receipt": receipt,
              "full_contexts_equal": True, "runs": runs}
    (OUT / "results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print("All six isolated runs matched complete dates, ranges, totals and summary fields in 11 contexts.")
    for run in runs:
        print(run["mode"], [(m["operation"], round(m["threadCPUMilliseconds"], 3), m["dateDerivations"])
                             for m in run["measurements"]])


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    receipt = compile_modes()
    if receipt is None:
        sys.exit(1)
    run_modes(receipt)
