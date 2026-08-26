import Foundation

/// One extra Codex card minted from a credential file that isn't the default home.
struct CodexExtraCard: Equatable, Sendable {
    var id: String
    var identityKey: String
    /// The account this card tracks: the dump's ChatGPT email, or the card id's hash suffix when the
    /// dump names no email. The dashboard shows it on hover of the card title; everywhere else it is
    /// folded into `Provider.displayName` ("Codex — extra@example.com").
    var accountLabel: String
    var credentialPath: String
}

/// One extra Claude card minted from a claude-swap slot: an account parked in claude-swap's stash
/// rather than signed in at `~/.claude`.
struct ClaudeSwapCard: Equatable, Sendable {
    var id: String
    var identityKey: String
    /// The slot's account label — its email, or the card id's hash suffix when the snapshot carried
    /// no email. The card title stays "Claude"; the label rides in the title's hover tooltip and is
    /// folded into `displayName` everywhere the name stands alone.
    var accountLabel: String
    /// The slot's config snapshot — the source anchor, and the file whose presence is the card's
    /// local-credential probe.
    var configPath: String
    /// claude-swap's slot number, which is also the key of its row in claude-swap's usage cache.
    var slot: String
    /// The slot's email address, per its config snapshot. Fences the cache row for a legacy identity
    /// that names no organization — claude-swap identifies a slot by (email, organizationUuid), and
    /// without the organization half the email is all that can tell a renumbered slot apart.
    var email: String?

    /// The organization half of the identity key, used to fence the cache row against a slot
    /// renumbering. `nil` for a legacy identity that names no organization.
    var organizationID: String? {
        let parts = identityKey.split(separator: "|")
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

struct ClaudeAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String
    let organizationID: String
    /// The organization this card tracks ("SUNSTORY", "Personal"). Only a dashboard with more than one
    /// Claude card uses it — see `ProviderCatalog`.
    let accountLabel: String
    let usesDesktopCredentials: Bool
    let allowsUnattributedPiUsage: Bool
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// reconcile the account registry, and expose the per-card identity map that the snapshot cache's
/// account stamp consumes. Runs once per launch (app) or per invocation (one-shot CLI); a mid-run
/// swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. Keys are record ids (`codex`,
    /// `codex@<hash8>`, `claude`, `claude@<hash8>`); a family whose identity didn't resolve is absent.
    let identityKeysByCard: [String: String]
    /// Extra Codex cards discovered this launch (not the default-home card).
    let extraCodexCards: [CodexExtraCard]
    /// Claude cards discovered this launch (default-home organization plus Desktop organizations).
    let claudeCards: [ClaudeAccountCard]
    /// Extra Claude cards discovered this launch in claude-swap's stash (never the active account).
    let claudeSwapCards: [ClaudeSwapCard]

    init(
        identityKeysByCard: [String: String],
        extraCodexCards: [CodexExtraCard] = [],
        claudeCards: [ClaudeAccountCard] = [],
        claudeSwapCards: [ClaudeSwapCard] = []
    ) {
        self.identityKeysByCard = identityKeysByCard
        self.extraCodexCards = extraCodexCards
        self.claudeCards = claudeCards
        self.claudeSwapCards = claudeSwapCards
    }

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports).
    static func make(defaults: UserDefaults = .standard, waitsForLoginShell: Bool) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, which pins identity-relevant keys to the persisted
        // shell-environment snapshot for the whole session, so identity and usage resolve the same
        // homes no matter when the async capture lands. The one unreadable state is a genuinely
        // FIRST Finder/Dock launch: capture still cold and no snapshot persisted yet — a
        // shell-exported home override would be invisible, so that family's read must be skipped
        // rather than misread as "no override". The skip is per family: a family whose home override
        // is already visible in the process environment (a terminal launch, `launchctl setenv`)
        // doesn't need the shell layers at all and still resolves.
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        // Extra Codex dumps live at ~/.cli-proxy-api and claude-swap's stash at ~/.claude-swap-backup,
        // neither of which moves with CODEX_HOME / CLAUDE_CONFIG_DIR — so both are safe to read even
        // when the default-home family is skipped for a cold login shell.
        let extraCodex = CodexAccountDiscovery().extraCredentials()
        let claudeSwap = ClaudeSwapDiscovery().extraCredentials()
        guard !families.isEmpty || !extraCodex.isEmpty || !claudeSwap.isEmpty else {
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: families,
            extraCodex: extraCodex,
            claudeSwap: claudeSwap
        )
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer and scratch
    /// store. `families` limits the pass to the families whose home facts are readable this launch
    /// (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it. Extra Codex
    /// credential dumps and claude-swap's stashed slots are independent of that skip and always mint
    /// their cards.
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        extraCodex: [CodexAccountDiscovery.ExtraCredential] = [],
        claudeSwap: [ClaudeSwapDiscovery.ExtraCredential] = [],
        desktop: ClaudeDesktopAuthStore? = nil,
        listDesktopOrganizationDirectories: @escaping @Sendable (URL) -> [String] = { root in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { return nil }
                return url.lastPathComponent
            }
        }
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.Observation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.Observation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        for extra in extraCodex {
            observations.append(ProviderAccountsStore.Observation(
                family: "codex",
                identityKey: extra.identityKey,
                label: extra.label,
                sources: [ProviderAccountSource(kind: .credentialFile, anchor: extra.path, holdsDefaultSource: false)]
            ))
            AppLog.info(.config, "accounts: extra Codex credential \(extra.path) identity \(extra.identityKey)")
        }

        for slot in claudeSwap {
            observations.append(ProviderAccountsStore.Observation(
                family: "claude",
                identityKey: slot.identityKey,
                // The organization-qualified label, not the bare email: `mergedObservations` keeps the
                // last non-nil label, and a Desktop organization card sharing this identity reads its
                // own name out of the record.
                label: slot.identityLabel ?? slot.label,
                sources: [ProviderAccountSource(kind: .credentialFile, anchor: slot.path, holdsDefaultSource: false)]
            ))
            AppLog.info(.config, "accounts: claude-swap slot \(slot.slot) (\(slot.path)) identity \(slot.identityKey)")
        }

        // Claude Desktop organizations join the same pass: only when the Claude family took part in
        // it, and only when the default-home identity is organization-scoped (a legacy identity with
        // no organization keeps the single bare `claude` card).
        let defaultClaudeIdentity = identityKeys["claude"]
        var desktopOrganizations: [DesktopOrganization] = []
        if families.contains("claude"), defaultClaudeIdentity.map({ $0.contains("|") }) ?? true {
            let desktop = desktop ?? ClaudeDesktopAuthStore(
                files: observer.files, homeDirectory: observer.homeDirectory
            )
            desktopOrganizations = discoverDesktopOrganizations(
                desktop: desktop,
                cliIdentity: defaultClaudeIdentity,
                listDirectories: listDesktopOrganizationDirectories
            )
            let desktopAnchor = desktop.homeDirectory()
                .appendingPathComponent("Library/Application Support/Claude").path
            for organization in desktopOrganizations {
                let source = ProviderAccountSource(
                    kind: .defaultHome, anchor: desktopAnchor, holdsDefaultSource: false
                )
                if let index = observations.firstIndex(where: {
                    $0.family == "claude" && $0.identityKey == organization.identityKey
                }) {
                    observations[index].sources.append(source)
                } else {
                    observations.append(ProviderAccountsStore.Observation(
                        family: "claude", identityKey: organization.identityKey,
                        label: organization.label, sources: [source]
                    ))
                }
            }
        }

        // One reconcile per pass, over deduplicated observations so two sightings of the same
        // account (a default-home login and an extra credential dump) collapse onto one record.
        let records = accountsStore.reconcile(with: mergedObservations(observations))

        var extraCards: [CodexExtraCard] = []
        let observedExtraPaths = Set(extraCodex.map(\.path))
        for record in records where !record.removedTombstone && record.family == "codex" {
            // The default-home card is always the bare `CodexProvider()`; extra dumps of that same
            // account attach as sources and must not mint a second runtime.
            guard !record.sources.contains(where: \.holdsDefaultSource) else { continue }
            guard let path = record.sources.first(where: { $0.kind == .credentialFile })?.anchor,
                  observedExtraPaths.contains(path)
            else { continue }
            identityKeys[record.id] = record.identityKey
            extraCards.append(CodexExtraCard(
                id: record.id,
                identityKey: record.identityKey,
                accountLabel: codexAccountLabel(label: record.label, id: record.id),
                credentialPath: path
            ))
        }
        extraCards.sort { $0.id < $1.id }

        let allowsUnattributedPiUsage = records.count { $0.family == "claude" } == 1
        var cards: [ClaudeAccountCard] = []
        if let defaultIdentity = defaultClaudeIdentity,
           let organization = defaultIdentity.split(separator: "|").last,
           defaultIdentity.contains("|"),
           let record = records.first(where: {
               $0.family == "claude" && $0.identityKey == defaultIdentity && !$0.removedTombstone
           })
        {
            let label = outcomes.first(where: { $0.family == "claude" }).flatMap { outcome -> String? in
                guard case .resolved(_, let value, _) = outcome.outcome else { return nil }
                return organizationLabel(value)
            } ?? "Organization"
            cards.append(ClaudeAccountCard(
                id: record.id, identityKey: defaultIdentity, organizationID: String(organization),
                accountLabel: label, usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedPiUsage
            ))
            identityKeys.removeValue(forKey: "claude")
            identityKeys[record.id] = defaultIdentity
        }
        for organization in desktopOrganizations where organization.identityKey != defaultClaudeIdentity {
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == organization.identityKey && !$0.removedTombstone
            }) else { continue }
            let cardID = record.id
            guard !cards.contains(where: { $0.id == cardID }) else { continue }
            cards.append(ClaudeAccountCard(
                id: cardID, identityKey: organization.identityKey, organizationID: organization.id,
                accountLabel: organizationLabel(record.label) ?? organization.label,
                usesDesktopCredentials: true, allowsUnattributedPiUsage: allowsUnattributedPiUsage
            ))
            identityKeys[cardID] = organization.identityKey
        }

        // claude-swap slots that are not already a card: a slot holding the same account as the
        // default home (or a Desktop organization) attached as an extra source on that record above
        // and must not mint a second card.
        //
        // The bare `claude` id is only off limits while something else answers to it: `ProviderCatalog`
        // emits a bare `ClaudeProvider()` exactly when no family card exists, so once the family cards
        // have taken hashed ids of their own the id is free. That matters after a `cswap switch` — the
        // account that owned `claude` when the registry was first written keeps that record id forever,
        // so refusing it outright would leave that account with no card at all while it is stashed.
        let bareClaudeIsClaimed = cards.isEmpty || cards.contains { $0.id == "claude" }
        var swapCards: [ClaudeSwapCard] = []
        for slot in claudeSwap {
            guard slot.identityKey != defaultClaudeIdentity else { continue }
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == slot.identityKey && !$0.removedTombstone
            }) else { continue }
            guard !(record.id == "claude" && bareClaudeIsClaimed) else { continue }
            guard !record.sources.contains(where: \.holdsDefaultSource) else { continue }
            guard !cards.contains(where: { $0.id == record.id }),
                  !swapCards.contains(where: { $0.id == record.id })
            else { continue }
            swapCards.append(ClaudeSwapCard(
                id: record.id,
                identityKey: record.identityKey,
                accountLabel: claudeSwapAccountLabel(label: slot.label ?? record.label, id: record.id),
                configPath: slot.path,
                slot: slot.slot,
                email: slot.label
            ))
            identityKeys[record.id] = record.identityKey
        }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys, extraCodexCards: extraCards, claudeCards: cards,
            claudeSwapCards: swapCards
        )
    }

    /// A claude-swap card's account label: the slot's email, or the card id's hash suffix when
    /// claude-swap's snapshot carried no email. Same shape as `codexAccountLabel`.
    static func claudeSwapAccountLabel(label: String?, id: String) -> String {
        if let label, !label.isEmpty { return label }
        return id.split(separator: "@").last.map(String.init) ?? id
    }

    /// One observation per (family, identity). A default-home login and an extra credential dump of
    /// the same ChatGPT account attach as two sources on one record — never two cards.
    private static func mergedObservations(
        _ observations: [ProviderAccountsStore.Observation]
    ) -> [ProviderAccountsStore.Observation] {
        var merged: [String: ProviderAccountsStore.Observation] = [:]
        var order: [String] = []
        for observation in observations {
            let key = observation.family + "\u{0}" + observation.identityKey
            if var existing = merged[key] {
                existing.label = observation.label ?? existing.label
                existing.sources = mergedSources(existing.sources, observation.sources)
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = observation
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func mergedSources(
        _ lhs: [ProviderAccountSource],
        _ rhs: [ProviderAccountSource]
    ) -> [ProviderAccountSource] {
        var result = lhs
        for source in rhs {
            if let index = result.firstIndex(where: { $0.kind == source.kind && $0.anchor == source.anchor }) {
                if source.holdsDefaultSource {
                    result[index].holdsDefaultSource = true
                }
            } else {
                result.append(source)
            }
        }
        return result
    }

    /// An extra Codex card's account label: the dump's email, or the card id's hash suffix when the
    /// dump names no account.
    static func codexAccountLabel(label: String?, id: String) -> String {
        if let label, !label.isEmpty { return label }
        return id.split(separator: "@").last.map(String.init) ?? id
    }

    private struct DesktopOrganization {
        var id: String
        var identityKey: String
        var label: String
    }

    private static func organizationLabel(_ value: String?) -> String? {
        guard let value, let opening = value.lastIndex(of: "("), value.last == ")" else { return value }
        return String(value[value.index(after: opening)..<value.index(before: value.endIndex)])
    }

    private static func discoverDesktopOrganizations(
        desktop: ClaudeDesktopAuthStore,
        cliIdentity: String?,
        listDirectories: @Sendable (URL) -> [String]
    ) -> [DesktopOrganization] {
        guard let user = desktop.lastKnownAccountUUID(), desktop.hasCredentialMaterial() else { return [] }
        let active = desktop.load(allowInteraction: false, expectedAccountUUID: user)
        let activeOrganization = active.organization

        let root = desktop.homeDirectory().appendingPathComponent("Library/Application Support/Claude")
        let memberships = Set(["claude-code-sessions", "local-agent-mode-sessions"].flatMap { directory in
            listDirectories(root.appendingPathComponent(directory).appendingPathComponent(user))
                .compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        })
        var organizations = memberships
        if let activeOrganization { organizations.insert(activeOrganization) }
        if let text = try? desktop.files.readTextIfPresent(root.appendingPathComponent("config.json").path),
           let rootObject = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        {
            organizations.formUnion(rootObject.keys.compactMap {
                $0.split(separator: ":").last.flatMap { UUID(uuidString: String($0))?.uuidString.lowercased() }
            })
        }
        if let text = try? desktop.files.readTextIfPresent(
            root.appendingPathComponent("plan-usage-history.json").path
        ), let history = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let samples = history["samples"] as? [[String: Any]]
        {
            organizations.formUnion(samples.compactMap {
                ($0["org"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            })
        }
        let cliOrganization = cliIdentity.flatMap { identity -> String? in
            let parts = identity.split(separator: "|")
            guard parts.count == 2,
                  String(parts[0]).caseInsensitiveCompare(user) == .orderedSame
            else { return nil }
            return String(parts[1]).lowercased()
        }

        return organizations.sorted { lhs, rhs in
            lhs == activeOrganization ? true : rhs == activeOrganization ? false : lhs < rhs
        }.compactMap { organization in
            guard memberships.contains(organization)
                || organization == activeOrganization || organization == cliOrganization
            else { return nil }
            let result = organization == activeOrganization ? active : desktop.load(
                allowInteraction: false, organization: organization, expectedAccountUUID: user
            )
            guard result.status == .available || result.status == .permissionRequired else { return nil }
            let plan = result.oauth?.subscriptionType?.lowercased()
            let label = plan.map { ["max", "pro", "free"].contains($0) } == true ? "Personal"
                : plan?.capitalized ?? "Organization \(organization.prefix(8))"
            return DesktopOrganization(id: organization, identityKey: "\(user)|\(organization)", label: label)
        }
    }
}
