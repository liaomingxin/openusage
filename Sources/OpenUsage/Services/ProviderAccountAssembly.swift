import Foundation

/// One extra Codex card minted from a credential file that isn't the default home.
struct CodexExtraCard: Equatable, Sendable {
    var id: String
    var identityKey: String
    var displayName: String
    var credentialPath: String
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// reconcile the account registry, and expose the per-card identity map that the snapshot cache's
/// account stamp consumes. Runs once per launch (app) or per invocation (one-shot CLI); a mid-run
/// swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. Keys are record ids (`codex`,
    /// `codex@<hash8>`); a family whose identity didn't resolve is absent.
    let identityKeysByCard: [String: String]
    /// Extra Codex cards discovered this launch (not the default-home card).
    let extraCodexCards: [CodexExtraCard]

    init(identityKeysByCard: [String: String], extraCodexCards: [CodexExtraCard] = []) {
        self.identityKeysByCard = identityKeysByCard
        self.extraCodexCards = extraCodexCards
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
        // Extra Codex dumps live at ~/.cli-proxy-api, not under CODEX_HOME, so they are safe to
        // read even when the default-home family is skipped for a cold login shell.
        let extraCodex = CodexAccountDiscovery().extraCredentials()
        guard !families.isEmpty || !extraCodex.isEmpty else {
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: families,
            extraCodex: extraCodex
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
    /// no identity key, no reconciliation, exactly as if the pass never ran for it.
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        extraCodex: [CodexAccountDiscovery.ExtraCredential] = []
    ) -> ProviderAccountAssembly {
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

        accountsStore.reconcile(with: mergedObservations(observations))

        var identityKeys: [String: String] = [:]
        var extraCards: [CodexExtraCard] = []
        let observedExtraPaths = Set(extraCodex.map(\.path))
        for record in accountsStore.records where !record.removedTombstone {
            identityKeys[record.id] = record.identityKey
            guard record.family == "codex" else { continue }
            // The default-home card is always the bare `CodexProvider()`; extra dumps of that same
            // account attach as sources and must not mint a second runtime.
            guard !record.sources.contains(where: \.holdsDefaultSource) else { continue }
            guard let path = record.sources.first(where: { $0.kind == .credentialFile })?.anchor,
                  observedExtraPaths.contains(path)
            else { continue }
            extraCards.append(CodexExtraCard(
                id: record.id,
                identityKey: record.identityKey,
                displayName: codexDisplayName(label: record.label, id: record.id),
                credentialPath: path
            ))
        }
        extraCards.sort { $0.id < $1.id }
        return ProviderAccountAssembly(identityKeysByCard: identityKeys, extraCodexCards: extraCards)
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

    static func codexDisplayName(label: String?, id: String) -> String {
        if let label, !label.isEmpty { return "Codex — \(label)" }
        let suffix = id.split(separator: "@").last.map(String.init) ?? id
        return "Codex — \(suffix)"
    }
}
