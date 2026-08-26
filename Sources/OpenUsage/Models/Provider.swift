import Foundation

/// A data source that can register widgets it knows how to feed.
struct Provider: Identifiable, Hashable {
    let id: String
    /// The family's name — "Claude", "Codex", "Cursor" — and the dashboard card's title. Never carries
    /// an account, so a long email can't truncate the title or crowd the plan badge beside it.
    let familyName: String
    /// Which account this card tracks when its family has more than one card: a ChatGPT email for an
    /// extra Codex card, an organization name for a Claude card. `nil` for a single-account card. The
    /// dashboard header shows it in the title's hover tooltip; `displayName` folds it into the name.
    let accountLabel: String?
    let icon: IconSource
    /// Per-provider quick links (e.g. "Status", "Console") shown as buttons in the card's expanded area.
    /// Declared inline by each provider; mirrors the legacy Tauri `PluginMeta.links`. Empty by default so
    /// providers without links and the existing `Provider(id:displayName:icon:)` call sites need no change.
    let links: [ProviderLink]

    /// The full, disambiguated name — "Codex — extra@example.com" — for every place the name stands on
    /// its own with no hover to help: context menus, the Customize title and its reset tooltip, the
    /// Total Spend legend, the menu bar, share cards, and the local API. Just the family name for a
    /// single-account card.
    var displayName: String {
        guard let accountLabel else { return familyName }
        return "\(familyName) — \(accountLabel)"
    }

    /// A single-account provider: `displayName` is the family name, and there is no account label.
    init(id: String, displayName: String, icon: IconSource, links: [ProviderLink] = []) {
        self.init(id: id, familyName: displayName, accountLabel: nil, icon: icon, links: links)
    }

    /// One card of a multi-account family. `ProviderCatalog` mints these from the launch account pass
    /// (`ProviderAccountAssembly`), which is where the label comes from.
    init(id: String, familyName: String, accountLabel: String?, icon: IconSource, links: [ProviderLink] = []) {
        self.id = id
        self.familyName = familyName
        self.accountLabel = accountLabel
        self.icon = icon
        self.links = links
    }

    /// Links safe to render: trimmed, non-empty label and URL, and an `http(s)` scheme only. Mirrors the
    /// legacy `visibleLinks` filter so a malformed entry never ships a dead or no-op button.
    var visibleLinks: [ProviderLink] {
        links.compactMap { link in
            let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !url.isEmpty,
                  url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return ProviderLink(label: label, url: url)
        }
    }
}

/// One external quick-link button on a provider card: a label and a URL opened in the default browser.
struct ProviderLink: Hashable {
    let label: String
    let url: String
}
