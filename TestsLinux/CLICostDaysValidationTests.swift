#if canImport(Glibc)
import CodexBarCore
import Foundation
import Testing

struct CLICostDaysValidationTests {
    @Test(arguments: ["abc", "7d", "1.5"])
    func `cost rejects a --days value that is not a whole number`(days: String) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-days-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("CodexBarCLI")

        do {
            let result = try await SubprocessRunner.run(
                binary: binary.path,
                arguments: ["cost", "--provider", "codex", "--days", days],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": home.path,
                    "CODEX_HOME": home.appendingPathComponent(".codex").path,
                    "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                ],
                timeout: 60,
                label: "cost-days-\(days)")
            Issue.record("Expected a failure, got stdout: \(result.stdout)")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 1)
            #expect(stderr.contains("--days must be a whole number"))
        }
    }
}
#endif
