"""Build and operate an isolated synthetic Settings proof; never launch the installed app."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

PROOF = Path(__file__).resolve().parent
REPOSITORY = PROOF.parents[2]
OUTPUT = REPOSITORY / ".build/hourly-days-proof"
RECEIPT = json.loads((PROOF / "build-receipt.json").read_text())
BUNDLE = OUTPUT / "SettingsDateProof.app"
EXECUTABLE = BUNDLE / "Contents/MacOS/SettingsDateProof"


def execute(arguments, **kwargs):
    subprocess.run(arguments, check=True, **kwargs)


def build():
    source = OUTPUT / "source"
    source.mkdir(parents=True, exist_ok=False)
    archive = OUTPUT / "baseline.tar"
    execute(["git", "archive", "--format=tar", f"--output={archive}", RECEIPT["baseline"]], cwd=REPOSITORY)
    execute(["tar", "-xf", str(archive), "-C", str(source)])
    archive.unlink()
    for relative, expected in RECEIPT["original_source_sha256"].items():
        assert hashlib.sha256((source / relative).read_bytes()).hexdigest() == expected, relative
    for name, key in [("fixture-launcher.swift", "fixture_sha256"),
                      ("FullSettingsDiagnostics.swift", "helper_sha256"),
                      ("instrumentation.patch", "instrumentation_sha256")]:
        assert hashlib.sha256((PROOF / name).read_bytes()).hexdigest() == RECEIPT[key], name
    expected_prototype = json.loads((PROOF / "measurements.json").read_text())["prototype_patch_sha256"]
    assert hashlib.sha256((PROOF / "prototype.patch").read_bytes()).hexdigest() == expected_prototype
    for name in ["instrumentation.patch", "prototype.patch"]:
        execute(["patch", "--batch", "-p1", "-i", str(PROOF / name)], cwd=source)
    shutil.copyfile(PROOF / "fixture-launcher.swift", source / "Sources/CodexBar/SpendDashboardAppProof.swift")
    shutil.copyfile(PROOF / "FullSettingsDiagnostics.swift", source / "Sources/CodexBar/FullSettingsDiagnostics.swift")
    # Reuse only dependency caches. Every compiler output belongs to this new archive.
    (source / ".build").mkdir()
    for name in ["artifacts", "checkouts", "repositories", "workspace-state.json"]:
        original = REPOSITORY / ".build" / name
        if original.exists():
            execute(["/bin/cp", "-c", "-R", str(original), str(source / ".build" / name)])
    execute(["swift", "build", "--build-system", "native", "-c", "release", "--product", "CodexBar",
             "--jobs", "4"], cwd=source)
    binaries = source / ".build/release"
    EXECUTABLE.parent.mkdir(parents=True)
    resources = BUNDLE / "Contents/Resources"
    frameworks = BUNDLE / "Contents/Frameworks"
    resources.mkdir()
    frameworks.mkdir()
    shutil.copyfile(binaries / "CodexBar", EXECUTABLE)
    EXECUTABLE.chmod(0o755)
    for resource in binaries.glob("*.bundle"):
        execute(["ditto", str(resource), str(resources / resource.name)])
    sparkle = next((source / ".build/artifacts").rglob("Sparkle.framework"))
    execute(["ditto", str(sparkle), str(frameworks / "Sparkle.framework")])
    with (BUNDLE / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleName": "Settings Date Proof", "CFBundleDisplayName": "Settings Date Proof",
                      "CFBundleIdentifier": "local.codexbar.settings-date-proof",
                      "CFBundleExecutable": EXECUTABLE.name, "CFBundlePackageType": "APPL",
                      "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                      "NSHighResolutionCapable": True}, file)
    execute(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(EXECUTABLE)])
    execute(["codesign", "--force", "--deep", "--sign", "-", str(BUNDLE)])
    execute(["codesign", "--verify", "--deep", "--strict", str(BUNDLE)])
    (OUTPUT / "rebuild-receipt.json").write_text(json.dumps({
        "baseline": RECEIPT["baseline"], "configuration": "Release (-O)", "synthetic_only": True,
        "executable_sha256": hashlib.sha256(EXECUTABLE.read_bytes()).hexdigest(),
    }, indent=2) + "\n")


def run(name, cached):
    assert EXECUTABLE.is_file(), "Build the proof first"
    directory = OUTPUT / name
    directory.mkdir(exist_ok=False)
    synthetic_home = directory / "synthetic-home"
    for relative in ["tmp", "Library/Caches"]:
        (synthetic_home / relative).mkdir(parents=True, exist_ok=True)
    # JSON string quoting is also valid for these sandbox path literals.
    personal_home = json.dumps(str(Path.home().resolve()))
    allowed_root = json.dumps(str(OUTPUT.resolve()))
    profile = directory / "sandbox.sb"
    profile.write_text('(version 1)\n(allow default)\n(deny network-outbound (remote ip "*:*"))\n'
                       f'(deny file-read* (require-all (subpath {personal_home}) '
                       f'(require-not (subpath {allowed_root}))))\n'
                       f'(deny file-write* (require-all (subpath {personal_home}) '
                       f'(require-not (subpath {allowed_root}))))\n')
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(synthetic_home),
        "CFFIXED_USER_HOME": str(synthetic_home), "TMPDIR": str(synthetic_home / "tmp") + "/",
        "SWIFT_TESTING": "1", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1", "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
        "CODEXBAR_DIAGNOSTIC_OUTPUT": str(directory), "CODEXBAR_FIXTURE_DAYS": "365",
        "CODEXBAR_DATE_CACHE_PROTOTYPE": "1" if cached else "0", "CODEXBAR_LOG_LEVEL": "error",
    }
    with (directory / "stdout.log").open("w") as log:
        process = subprocess.Popen(["/usr/bin/sandbox-exec", "-f", str(profile), str(EXECUTABLE)],
                                   cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
        print(f"Synthetic proof running: {name}; cached={cached}", flush=True)
        try:
            code = process.wait(timeout=1200)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        (directory / "exit.json").write_text(json.dumps({"code": code, "synthetic_only": True}) + "\n")
        assert code == 0, "Diagnostic app exited unsuccessfully"


def send(name, action, value):
    directory = OUTPUT / name
    assert directory.is_dir(), "Start this proof run first"
    command = {"action": action, "id": str(time.time_ns())}
    if value is not None:
        command["name" if action in ["checkpoint", "finish"] else "value"] = value
    temporary = directory / "command.pending"
    temporary.write_text(json.dumps(command))
    temporary.replace(directory / "command.json")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        acknowledgement = directory / "ack.txt"
        if acknowledgement.exists() and acknowledgement.read_text() == command["id"]:
            return
        if action == "finish" and (directory / "runtime.json").exists():
            records = json.loads((directory / "runtime.json").read_text())
            if records and records[-1]["checkpoint"] == command.get("name", "finished"):
                return
        time.sleep(0.1)
    raise RuntimeError("Diagnostic command was not acknowledged")


parser = argparse.ArgumentParser(description=__doc__)
commands = parser.add_subparsers(dest="command", required=True)
commands.add_parser("build")
run_parser = commands.add_parser("run")
run_parser.add_argument("name")
run_parser.add_argument("--cached", action="store_true")
send_parser = commands.add_parser("send")
send_parser.add_argument("name")
send_parser.add_argument("action", choices=["checkpoint", "verify", "time-zone", "period", "day", "finish"])
send_parser.add_argument("value", nargs="?")
arguments = parser.parse_args()
if arguments.command == "build":
    build()
elif arguments.command == "run":
    run(arguments.name, arguments.cached)
else:
    send(arguments.name, arguments.action, arguments.value)
