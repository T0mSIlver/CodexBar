# Langdock browser profile settings

These images render the shared settings rows with synthetic profiles. They do not show real
accounts, browser sessions, or macOS permissions.

- [Chrome](langdock-settings-chrome.png)
- [Safari](langdock-settings-safari.png)

Generated with the opt-in `LangdockProfileScreenshotTests` hook on macOS using the same
`ProviderSettingsPickerRowView` used by the provider settings pane. The test uses in-memory
defaults and isolated configuration files; no browser-cookie import or HTTP request is made.

```sh
export CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS=0 CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1
export CODEXBAR_LANGDOCK_PROOF_DIR="$PWD/.build/langdock-browser-proof"
source Scripts/test_environment.sh
swift test --skip-build --filter LangdockProfileScreenshotTests
```

The Safari fixture name is deliberately synthetic. The current importer can display a Safari
WebsiteDataStore identifier in place of the profile's friendly name. The actual saved selection
is bound to the concrete cookie-file path, so removing that file cannot select another store
with the same datastore identifier.
