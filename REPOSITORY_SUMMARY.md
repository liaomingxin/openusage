# Repository Analysis: OpenUsage

## Overview

OpenUsage is a macOS menu-bar app that shows how much of a person's AI coding subscriptions they have used — session and weekly limits, credits, and estimated spend — in one popover, with optional pins in the menu bar itself.

This working copy is the **native Swift edition** (0.7.x and up). The original product was a Tauri/web app whose last frozen release is `v0.6.28` on the `tauri-legacy` branch. Active development lives on `main`. The remote `origin` for this checkout is the personal fork `liaomingxin/openusage`; upstream is `robinebers/openusage`.

The app reads credentials that already exist on the machine (keychain, CLI auth files, app state). It does not ask users to paste tokens for the established providers. OpenRouter and Z.ai are the exceptions: they take an API key. Spend tiles for Claude, Codex, Cursor, and Grok are imputed locally through a shared pricing engine.

## Architecture

SwiftPM package, Swift 6 strict concurrency, macOS 15+. There is no Xcode project. A shared `OpenUsage` module feeds two thin executables:

- `OpenUsage` — the menu-bar GUI (`Sources/OpenUsageApp`)
- `openusage-cli` — a one-shot reader of the same five-minute cache (`Sources/OpenUsageCLI`)

SwiftUI content is hosted inside an AppKit-owned `NSStatusItem` and a custom, key-capable `NSPanel`. A stock `NSPopover` cannot reliably become key for an accessory app, so the panel exists specifically so keyboard navigation and the shortcut recorder work on the first click.

`AppContainer` is the composition root. At launch it builds the provider list from `ProviderCatalog`, turns it into a `WidgetRegistry`, creates the stores, starts the refresh loop, and starts the loopback HTTP API on `127.0.0.1:6736`.

Each provider conforms to `ProviderRuntime`:

1. **Auth store** — load credentials already on disk / in the keychain
2. **Usage client** — call the provider API
3. **Mapper** — normalize into `ProviderSnapshot` / `MetricLine`

The UI never speaks a provider's native JSON. It only renders normalized meters, badges, charts, and notices.

## Key Components

- **`App/`** — startup, single-instance lock, status item, panel geometry, Sparkle updater, first-run and new-provider seeders.
- **`Models/`** — `MetricLine`, `WidgetData`, `ProviderSnapshot`, layout descriptors, menu-bar content.
- **`Providers/`** — one folder per vendor (Claude, Codex, Cursor, Antigravity, Copilot, Devin, Grok, Kimi, OpenCode, OpenRouter, Z.ai) plus shared scanners (`IncrementalJSONLScanner`) and the catalog.
- **`Pricing/`** — layered rates: live `pricing_supplement.json` (published to gh-pages) over bundled LiteLLM and models.dev snapshots.
- **`Stores/`** — observable app state: `WidgetDataStore` (snapshots + refresh), `LayoutStore` (order, visibility, pins), `ProviderEnablementStore`, `ProviderAccountsStore`, `ICloudUsageSyncStore`.
- **`Services/`** — HTTP client, proxy, local limits/usage API, process runner, usage-history aggregation, login-shell environment.
- **`Views/`** — dashboard, customize, settings, menu-bar strip, share card.
- **`Tests/`** — 140 Swift test files; provider mappers, layout persistence, menu-bar rendering, pricing, and iCloud sync are the dense areas.
- **`script/`** — `build_and_run.sh` (dev), `release.sh` (universal signed DMG), icon/entitlements helpers.
- **`.agents/skills/`** — release, pricing-update, and macOS agent skills used by the maintainer and coding agents.

## Technologies Used

| Layer | Choice |
|---|---|
| Language | Swift 6.2 / language mode v6 |
| Package | SwiftPM (`Package.swift`) |
| UI | SwiftUI + AppKit (`NSStatusItem`, `NSPanel`) |
| Platform | macOS 15 Sequoia+; Liquid Glass on macOS 26 Tahoe with fallbacks in `Support/LiquidGlassFallbacks.swift` |
| Updates | Sparkle (EdDSA-signed DMG, beta vs stable appcast on `gh-pages`) |
| Hotkeys | sindresorhus/KeyboardShortcuts |
| Telemetry | PostHog iOS (anonymous usage + mandatory crash reporting, extra analytics optional) |
| CI | GitHub Actions (`release.yml` upstream; this fork also has `personal-release.yml`) |
| Distribution | Homebrew cask + GitHub Releases DMG |

## Data Flow

```
local credentials (keychain / CLI files / API key)
        │
        ▼
 ProviderRuntime.refresh()
        │
        ├── usage API  ──► mapper ──► ProviderSnapshot
        └── local JSONL logs ──► IncrementalJSONLScanner ──► spend tiles
                                      │
                                      ▼
                              Pricing engine
                    (supplement > LiteLLM > models.dev)
        │
        ▼
 WidgetDataStore  (stale-while-revalidate, 5-minute cache)
        │
        ├── Dashboard / menu-bar pins
        ├── openusage CLI  (`--force` bypasses freshness)
        ├── 127.0.0.1:6736/v1/limits  (and legacy /v1/usage)
        └── iCloudUsageSyncStore  (peer Mac history, spend rows only)
```

Refresh is timer-driven from `AppContainer`. Cached snapshots paint immediately at launch. Network is hit only when a snapshot has expired, with a 30-second timeout so a hung provider cannot spin forever.

## Team and Ownership

On `main` (~546 commits since the Swift rewrite, 2026-06-15 → 2026-08-25):

| Person | Role in this tree |
|---|---|
| **Robin Ebers** (`@robinebers`) | Owner. ~480 of 546 commits. Architecture, releases, most providers, dashboard, Sparkle, docs. |
| **Mert Can Demir** (`@validatedev`) | Pricing accuracy, Grok weekly pool, Antigravity quota representation, Copilot/token-cost fixes. |
| **David Arutyunyan** (`@davidarny`) | UI performance (translucent scroll), Reduce Animations, Z.ai credit quotas. |
| **dependabot** | Sparkle, PostHog, GitHub Actions bumps. |
| **liaomingxin** | This fork: Kimi Code provider, personal release workflow, `FORK.md`. |
| Others | Targeted PRs: Copilot org billing, Cursor Enterprise, Claude Desktop login ranking, Reset All Settings, refresh timeout, pi coding-agent logs. |

Coding agents (Claude Code, Cursor, Codex) are first-class collaborators: remote branches are prefixed `claude/`, `cursor/`, `codex/`, `agent/`. Many commits are co-authored by `Cursor Agent` even when the Git author is Robin.

External contributions are **issue-first and gated** (`CONTRIBUTING.md`): no maintainer-approved issue, PRs larger than 1,000 lines, or visual changes without screenshots are auto-closed.
