import Foundation
import Testing
@testable import CodexBarCore

struct CodexBarConfigStoreDecodeErrorTests {
    @Test(arguments: [
        ("{", "invalid JSON"),
        ("{\"version\": 1,\n\"providers\": [{\"id\": \"codex\" \"enabled\": true}]}", "invalid JSON"),
        ("{}", "missing key 'version'"),
        ("{\"version\": 1}", "missing key 'providers'"),
        ("{\"version\": \"1\", \"providers\": []}", "'version'"),
        ("{\"version\": 1, \"providers\": [{\"id\": \"codex\", \"enabled\": \"yes\"}]}", "'providers[0].enabled'"),
    ])
    func `malformed config errors say what is wrong and where`(contents: String, expected: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try Data(contents.utf8).write(to: store.fileURL)

        let error = try #require(throws: CodexBarConfigStoreError.self) { try store.load() }
        guard case let .decodeFailed(details) = error else {
            Issue.record("Expected decodeFailed, got \(error)")
            return
        }
        #expect(details.contains(expected))
    }
}
