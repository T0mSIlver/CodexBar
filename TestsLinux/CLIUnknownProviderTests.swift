#if canImport(Glibc)
import CodexBarCore
import Foundation
import Testing

struct CLIUnknownProviderTests {
    @Test(arguments: [["usage"], ["cards"], ["cost"]])
    func `unknown --provider fails instead of falling back to enabled providers`(command: [String]) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-unknown-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("CodexBarCLI")

        do {
            let result = try await SubprocessRunner.run(
                binary: binary.path,
                arguments: command + ["--provider", "claud"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": home.path,
                    "CODEX_HOME": home.appendingPathComponent(".codex").path,
                    "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                ],
                timeout: 60,
                label: "unknown-provider-\(command[0])")
            Issue.record("Expected a failure, got stdout: \(result.stdout)")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 1)
            #expect(stderr.contains("unknown provider 'claud'"))
        }
    }
}
#endif
