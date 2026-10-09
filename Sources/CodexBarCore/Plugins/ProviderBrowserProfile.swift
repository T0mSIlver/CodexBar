import Foundation
#if os(macOS)
import SweetCookieKit
#endif

public struct ProviderBrowserProfile: Sendable, Equatable {
    public let browserID: String
    public let profileID: String

    public init(browserID: String, profileID: String) {
        self.browserID = browserID
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func selected(in config: ProviderConfig?, browsers: [String]) -> Self? {
        if config?.extensionValues["browserID"] != nil, config?.browserID == nil { return nil }
        guard let browserID = config?.browserID ?? browsers.first, browsers.contains(browserID) else { return nil }
        return Self(browserID: browserID, profileID: config?.browserProfileID ?? "")
    }

    #if os(macOS)
    public static func selectableProfile(for store: BrowserCookieStore) -> BrowserProfile? {
        guard let file = store.databaseURL else { return nil }
        // Safari datastore IDs can move to another file when a duplicate store disappears.
        return BrowserProfile(
            id: store.browser == .safari ? file.standardizedFileURL.path : store.profile.id,
            name: store.profile.name)
    }

    static func selectedStore(_ selection: Self, from stores: [BrowserCookieStore]) throws -> BrowserCookieStore {
        let matching = stores.filter {
            $0.browser.rawValue == selection.browserID && Self.selectableProfile(for: $0)?.id == selection.profileID
        }
        guard let store = matching.first(where: { $0.kind == .network })
            ?? matching.first(where: { $0.kind == .primary })
            ?? matching.first(where: { $0.kind == .safari })
        else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential, message: "The selected browser profile has no discoverable cookie store.")
        }
        return store
    }
    #endif

    static func read(_ selection: Self, domains: Set<String>) throws -> [ProviderPluginCookieRecord] {
        #if os(macOS)
        guard let browser = Browser(rawValue: selection.browserID) else {
            throw ProviderPluginError.secretAccess("unsupported selected browser")
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else {
            throw ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: "Browser cookie access is blocked. Check Keychain access and refresh manually.")
        }
        let client = BrowserCookieClient()
        let store: BrowserCookieStore
        do {
            store = try Self.selectedStore(selection, from: client.codexBarStores(for: browser))
        } catch {
            if BrowserDetection.selectedChromiumProfileAccessIssue(
                profileID: selection.profileID,
                browser: browser,
                homeDirectories: client.configuration.homeDirectories) == .accessDenied
            {
                throw ProviderFetchClassifiedError(
                    kind: .permissionDenied,
                    message: "Cannot read the selected browser profile. Check Files & Folders access.")
            }
            throw error
        }
        do {
            return try client.codexBarRecords(
                matching: BrowserCookieQuery(domains: domains.sorted(), domainMatch: .exact), in: store)
                .map(ProviderPluginCookieRecord.init)
        } catch let error as BrowserCookieError {
            guard case .accessDenied = error else { throw error }
            throw ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: browser == .safari
                    ? "Cannot read Safari cookies. Check Full Disk Access for CodexBar."
                    : "Cannot decrypt the selected profile. Check browser Keychain access.")
        }
        #else
        throw ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: "Selected browser profiles require macOS.")
        #endif
    }
}

extension ProviderConfig {
    public var browserID: String? {
        get { self.extensionValue(forKey: "browserID") }
        set { self.setExtensionValue(newValue, forKey: "browserID") }
    }

    public var browserProfileID: String? {
        get { self.extensionValue(forKey: "browserProfileID") }
        set { self.setExtensionValue(newValue, forKey: "browserProfileID") }
    }
}

extension ProviderSettingsSectionRegistration {
    var selectedProfileCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        self.selectedProfileBrowsers.map { $0.compactMap(Browser.init(rawValue:)) }
        #else
        nil
        #endif
    }
}
