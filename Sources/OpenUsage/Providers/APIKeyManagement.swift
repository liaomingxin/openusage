import Foundation

/// The live status of a provider's user-supplied API key, shown in its Customize ▸ API Key section.
/// Maps to the four states the provider-neutral key editor renders:
///
/// - `notSet`: no key in the environment or the saved file — the card offers an Add field.
/// - `fromEnvironment`: a key is present in the environment only — shown read-only, with an
///   override checkbox.
/// - `saved`: a key was saved via the app (written to the config file) and no env key is present —
///   shown as "Saved in App", with reveal and clear controls in Edit mode.
/// - `overrideActive`: a saved key is overriding a key also present in the environment — shown as
///   "Custom Key", with reveal and clear controls (clearing falls back to the environment key).
///
/// The auth store's existing precedence (config file > env) is what makes a saved key an override
/// for free; this type just reports which combination is present.
enum APIKeyStatus: Sendable, Equatable {
    case notSet
    case fromEnvironment
    case saved
    case overrideActive
}

/// A `ProviderRuntime` that needs a user-supplied API key (currently OpenRouter and Z.ai). The
/// provider's Customize detail renders `apiKeyStatus` and writes changes through `saveAPIKey` /
/// `deleteAPIKey`. The provider delegates to its auth store, so the UI stays provider-agnostic and
/// writes the same config file the auth store already reads — no parallel credential storage.
@MainActor
protocol APIKeyManaging: ProviderRuntime {
    /// The live key status, computed from the environment + the saved config file.
    var apiKeyStatus: APIKeyStatus { get }
    /// The effective key currently in use (config > env), surfaced only when the user clicks the
    /// reveal toggle. `nil` when no key is present.
    func currentAPIKey() -> String?
    /// Persist `key` to the storage the auth store already reads (the config file). A saved key
    /// automatically takes precedence over an env var.
    func saveAPIKey(_ key: String) throws
    /// Remove the saved key. If an env key is present the status falls back to `fromEnvironment`;
    /// otherwise `notSet`.
    func deleteAPIKey() throws
}

/// One selectable API platform for a provider that publishes the same API on more than one console.
/// `host` is shown under the option so the choice reads as "which server am I talking to".
struct ProviderPlatformOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let host: String
}

/// An `APIKeyManaging` provider whose key only works on one of several consoles, so the console is
/// part of the credential rather than a global setting (today only Z.ai: the global `api.z.ai` and
/// the China `open.bigmodel.cn`). The provider's API Key card renders the picker and writes the
/// choice next to the key, so both travel together and no request can go to the wrong host.
@MainActor
protocol ProviderPlatformSelecting: APIKeyManaging {
    var platformOptions: [ProviderPlatformOption] { get }
    var selectedPlatformID: String { get }
    func selectPlatform(_ id: String) throws
}
