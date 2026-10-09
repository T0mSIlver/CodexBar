import Foundation
import os.lock
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct LangdockBrowserProfileTests {
    @MainActor
    @Test(arguments: LangdockPluginTests.profiles)
    func `browser selection survives config serialization and app and CLI settings`(
        profile: ProviderBrowserProfile) throws
    {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "\(#function)-\(profile.browserID)")
        defer {
            try? FileManager.default.removeItem(at: fixture.settings.configStore.fileURL.deletingLastPathComponent())
        }
        fixture.settings.updateProviderConfig(provider: .langdock) {
            $0.browserID = profile.browserID
            $0.browserProfileID = profile.profileID
        }
        let config = try #require(fixture.settings.providerConfig(for: .langdock))
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.browserID == profile.browserID)
        #expect(decoded.browserProfileID == profile.profileID)
        let section = LangdockProviderDescriptor.descriptor.settingsSection
        let implementation = PluginCookieProviderImplementation(spec: LangdockProviderDescriptor.spec)
        let cli = try TokenAccountCLIContext(
            selection: .init(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [decoded]),
            verbose: false,
            baseEnvironment: [:])
        #expect(try section.cookieSettings(from: #require(cli.settingsSnapshot(for: .langdock, account: nil)))?
            .selectedBrowserProfile == profile)
        let app = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        #expect(section.cookieSettings(from: .init(contributions: [app]))?.selectedBrowserProfile == profile)
    }

    @Test
    func `old Edge configuration is preserved and unsupported browsers fail closed`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LangdockLegacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        let legacy = """
        {"version":1,"providers":[{"id":"langdock","enabled":true,"source":"web","cookieSource":"auto",
        "browserProfileID":"/synthetic/Edge/Profile 2"}]}
        """
        try store.saveEncodedData(Data(legacy.utf8))
        let loaded = try #require(try store.load())
        let section = LangdockProviderDescriptor.descriptor.settingsSection
        let browsers = try #require(section.selectedProfileBrowsers)
        for roundTrip in [false, true] {
            if roundTrip { try store.save(loaded) }
            let saved = try #require(try store.load())
            let config = try #require(saved.providerConfig(for: .langdock))
            #expect(config.browserID == nil)
            #expect(config.browserProfileID == LangdockPluginTests.profile.profileID)
            let cli = try TokenAccountCLIContext(
                selection: .init(label: nil, index: nil, allAccounts: false),
                config: saved,
                verbose: false,
                baseEnvironment: [:],
                configStore: store)
            #expect(try section.cookieSettings(from: #require(cli.settingsSnapshot(for: .langdock, account: nil)))?
                .selectedBrowserProfile == LangdockPluginTests.profile)
        }
        var config = try #require(loaded.providerConfig(for: .langdock))
        #expect(ProviderBrowserProfile.selected(in: config, browsers: browsers) == LangdockPluginTests.profile)
        #expect(ProviderBrowserProfile.selected(in: nil, browsers: browsers)?.profileID.isEmpty == true)
        for invalid in ["firefox", "", "Chrome"] {
            config.browserID = invalid
            #expect(ProviderBrowserProfile.selected(in: config, browsers: browsers) == nil)
            let contribution = try #require(section.credentialContribution(context: .init(
                config: config,
                account: nil)))
            #expect(section.cookieSettings(from: .init(contributions: [contribution]))?.selectedBrowserProfile == nil)
        }
        let malformed = try JSONDecoder().decode(ProviderConfig.self, from: Data(
            #"{"id":"langdock","browserID":42,"browserProfileID":"/synthetic/Edge/Profile 2"}"#.utf8))
        #expect(ProviderBrowserProfile.selected(in: malformed, browsers: browsers) == nil)
    }

    @Test
    func `single browser registration API remains compatible`() throws {
        let section = ProviderSettingsSectionRegistration(
            LangdockProviderSettingsKey.self,
            selectedProfileBrowser: "edge")
        #expect(section.selectedProfileBrowser == "edge")
        #expect(section.selectedProfileBrowsers == ["edge"])
        #expect(LangdockProviderDescriptor.descriptor.settingsSection.selectedProfileBrowser == nil)
        var config = ProviderConfig(id: .langdock)
        config.browserProfileID = LangdockPluginTests.profile.profileID
        let contribution = try #require(section.credentialContribution(context: .init(config: config, account: nil)))
        #expect(section.cookieSettings(from: .init(contributions: [contribution]))?.selectedBrowserProfile
            == LangdockPluginTests.profile)
    }

    @MainActor
    @Test(arguments: LangdockPluginTests.profiles)
    func `browser changes clear usage retire pending work and require a new explicit profile`(
        profile: ProviderBrowserProfile) async throws
    {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "\(#function)-\(profile.browserID)")
        defer {
            try? FileManager.default.removeItem(at: fixture.settings.configStore.fileURL.deletingLastPathComponent())
        }
        let implementation = PluginCookieProviderImplementation(spec: LangdockProviderDescriptor.spec)
        let context = fixture.settingsContext(provider: .langdock)
        let browsers = try #require(LangdockProviderDescriptor.descriptor.settingsSection.selectedProfileBrowsers)
        let original = try #require(LangdockPluginTests.profiles.first { $0.browserID != profile.browserID })
        fixture.settings.updateProviderConfig(provider: .langdock) {
            $0.browserID = original.browserID
            $0.browserProfileID = original.profileID
        }
        let oldPicker = implementation.browserProfilePicker(
            browser: original.browserID, context: context, profiles: [.init(id: original.profileID, name: "Original")])
        let usage = try await LangdockPluginTests.fetch(
            LangdockPluginTests.body(LangdockPluginTests.plan),
            profile: original)
        fixture.store.snapshots[.langdock] = usage
        let revision = fixture.store.providerPublicationRevision(for: .langdock)
        #expect(fixture.store.snapshot(for: .langdock) != nil)
        let browserPicker = implementation.browserPicker(browsers: browsers, context: context)
        #expect(browserPicker.options.map(\.id) == ["edge", "chrome", "safari"])
        browserPicker.binding.wrappedValue = profile.browserID
        #expect(fixture.settings.providerConfig(for: .langdock)?.browserProfileID == nil)
        #expect(fixture.store.snapshots[.langdock] == nil)
        #expect(!fixture.store.providerPublicationRevisionIsCurrent(revision, for: .langdock))
        oldPicker.binding.wrappedValue = original.profileID
        #expect(fixture.settings.providerConfig(for: .langdock)?.browserProfileID == nil)
        let picker = implementation.browserProfilePicker(
            browser: profile.browserID, context: context, profiles: [.init(id: profile.profileID, name: "Selected")])
        #expect(picker.binding.wrappedValue.isEmpty)
        picker.binding.wrappedValue = profile.profileID
        #expect(fixture.settings.providerConfig(for: .langdock)?.browserProfileID == profile.profileID)
        browserPicker.binding.wrappedValue = profile.browserID
        #expect(fixture.settings.providerConfig(for: .langdock)?.browserProfileID == profile.profileID)
        fixture.store.snapshots[.langdock] = usage
        #expect(fixture.store.snapshot(for: .langdock) == nil)
    }

    @Test
    func `Safari placeholders cannot invoke a browser wide fallback`() {
        let placeholder = BrowserCookieStore(
            browser: .safari,
            profile: .init(id: "safari.default", name: "Default"),
            kind: .safari,
            label: "Safari",
            databaseURL: nil)
        #expect(ProviderBrowserProfile.selectableProfile(for: placeholder) == nil)
        #expect(throws: ProviderFetchClassifiedError.self) {
            try ProviderBrowserProfile.selectedStore(
                .init(browserID: "safari", profileID: "safari.default"), from: [placeholder])
        }
    }
}

struct LangdockSafariImportTests {
    @Test(arguments: BundledPluginTestSupport.engines, ["success", "removed", "changed"])
    func `Safari imports only the selected real synthetic store and rechecks it after HTTP`(
        engine: ProviderPluginEngineKind, outcome: String) async throws
    {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("LangdockSafari-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let selectedID = "00000000-0000-0000-0000-000000000002"
        let selectedFile = home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore")
            .appendingPathComponent("\(selectedID)/WebsiteData/Cookies/Cookies.binarycookies")
        let duplicateFile = home.appendingPathComponent(
            "Library/WebKit/WebsiteDataStore/\(selectedID)/WebsiteData/Cookies/Cookies.binarycookies")
        let otherFile = home
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        for (file, value) in [
            (otherFile, "synthetic-other-account"),
            (duplicateFile, "synthetic-duplicate-account"),
            (selectedFile, "synthetic-account-a"),
        ] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Self.cookieData(value: value).write(to: file)
        }
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let profile = ProviderBrowserProfile(browserID: "safari", profileID: selectedFile.standardizedFileURL.path)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let runtime = try BundledPluginTestSupport.runtime(
            "langdock", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-account-a")
                if outcome == "removed" { try FileManager.default.removeItem(at: selectedFile) }
                if outcome == "changed" { try Self.cookieData(value: "synthetic-account-b").write(to: selectedFile) }
                let url = try #require(request.url)
                return try (Data(LangdockPluginTests.body(LangdockPluginTests.plan).utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
        let reader: ProviderPluginSelectedProfile.Reader = { selection in
            #expect(selection == profile)
            reads.withLock { $0 += 1 }
            let store = try ProviderBrowserProfile.selectedStore(selection, from: client.codexBarStores(for: .safari))
            return try client.codexBarRecords(
                matching: .init(domains: ["langdock.com", "app.langdock.com"], domainMatch: .exact), in: store)
                .map(ProviderPluginCookieRecord.init)
        }
        let broker = LangdockPluginTests.broker(runtime, profile: profile, reader: reader)
        if outcome == "success" {
            let usage = try await runtime.fetchResult(cookies: broker).usage
            #expect(usage.browserSessionOwner?.profile == profile)
            #expect(usage.primary?.usedPercent == 12.5)
            #expect(usage.secondary?.usedPercent == 104.2)
        } else {
            let failure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
                try await runtime.fetchResult(cookies: broker)
            })
            #expect(failure.owner == nil)
            #expect((failure.underlyingError as? ProviderFetchClassifiedError)?.kind == (
                outcome == "removed" ? .missingCredential : .authenticationExpired))
        }
        #expect(reads.withLock { $0 } == 2)
        if outcome == "removed" {
            let remaining = try #require(client.codexBarStores(for: .safari).first {
                ProviderBrowserProfile.selectableProfile(for: $0)?.id == duplicateFile.standardizedFileURL.path
            })
            #expect(remaining.profile.id == "safari.datastore.\(selectedID)")
            let nextFailure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
                try await runtime.fetchResult(cookies: LangdockPluginTests.broker(
                    runtime,
                    profile: profile,
                    reader: reader))
            })
            #expect(nextFailure.owner == nil)
            #expect((nextFailure.underlyingError as? ProviderFetchClassifiedError)?.kind == .missingCredential)
            #expect(reads.withLock { $0 } == 3)
        }
    }

    private static func cookieData(value: String) -> Data {
        func littleEndian(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        let strings = [".langdock.com", "auth_token", "/", value]
        var offset = 56
        let offsets = strings.map { string -> UInt32 in
            defer { offset += string.utf8.count + 1 }
            return UInt32(offset)
        }
        var record = ([UInt32(offset), 0, 5, 0] + offsets + [0, 0])
            .reduce(into: Data()) { $0.append(littleEndian($1)) }
        record.append(Data(repeating: 0, count: 16))
        for string in strings {
            record.append(Data(string.utf8)); record.append(0)
        }
        var page = [UInt32(0), 1, 12].reduce(into: Data()) { $0.append(littleEndian($1)) }
        page.append(record)
        var file = Data("cook".utf8)
        file.append(withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) })
        file.append(withUnsafeBytes(of: UInt32(page.count).bigEndian) { Data($0) })
        file.append(page)
        return file
    }
}
