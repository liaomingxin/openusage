# The Story of OpenUsage

This is the story of the **Swift** OpenUsage, told from `git` on `main`. The Tauri original still exists — 507 commits, last tag `v0.6.28` on `origin/tauri-legacy` — but it is a closed book. Everything below starts on 15 June 2026, when Robin Ebers landed a single commit that rewrote the product.

## The Chronicles: A Year in Numbers

There is no “past year” in the usual sense. The entire `main` history is **72 days**.

| Measure | Value |
|---|---|
| Commits on `main` | 546 |
| Commits reachable `--all` (every remote agent branch) | 1,638 |
| First commit | 2026-06-15 `53bc2f0` — *OpenUsage — native Swift edition* (200 files, +19,774 lines) |
| Latest upstream-shaped tag | `v0.7.10-beta.2` (2026-08-24) |
| This fork's tag | `v0.7.10-kimi.1` (2026-08-25) |
| Swift files: rewrite → now | 116 → 385 |
| Test files: rewrite → now | 31 → 140 |
| Merge commits on `main` | 122 |
| Subjects containing `(#NNN)` | 147 |

Monthly rhythm on `main`:

| Month | Commits | Character |
|---|---|---|
| 2026-06 (from the 15th) | 176 | Rewrite, sixteen betas, first stable `v0.7.0` |
| 2026-07 | 323 | Peak. Providers, native spend, iCloud, CLI, a 90-commit split day |
| 2026-08 (to the 25th) | 47 | Slower. Account-first start-and-revert, then this fork's Kimi work |

Weekly peaks: **W28 (6–12 July) = 182 commits**. The quiet stretch is W30–W32 (late July into early August), then a modest return in August.

Busiest single day: **8 July 2026, 91 commits** — almost all `codex/extract-*` and `claude/split-*` PRs, keeping files under the ~500 LOC house rule.

## Cast of Characters

### Robin Ebers — the author who ships every day

Git author `Robin Ebers` accounts for **480 of 546** `main` commits (two emails: `robin.ebers@gmail.com` and `rob@robinebers.com`). He writes the architecture, cuts the Sparkle releases, owns Claude/Codex/Cursor, and keeps `CHANGELOG.md` (47 edits, the third-hottest file) honest. Timezone on his commits is mostly `+0400`. He works through the afternoon: 11:00–16:00 is the dense band, with a long tail into the evening.

He also runs an **agent studio**. Remote branches tell the collaboration model better than the author field:

- 62 `codex/*` branches
- 34 `claude/*` branches
- 11 `cursor/*` branches
- plus `agent/*`, `feat/*`, `fix/*`

A typical landed commit on `main` is authored by Robin and `Co-authored-by: Cursor <cursoragent@cursor.com>`. Twelve commits are authored as `Claude <noreply@anthropic.com>`. The agents do the splits, the provider probes, the review-fix rounds; Robin merges, names the release, and writes the human changelog.

### Mert Can Demir (`@validatedev`) — the pricing skeptic

Sixteen commits on `main`, outsized impact. When spend numbers are wrong, Mert shows up: Codex auto-review priced as GPT-5.6 Luna, Claude Opus 5 in the supplement, Grok weekly pool via gRPC-web, Antigravity's merged Gemini pool, token-cost discrepancies, `Increase Transparency` legibility. He is the person who treats a dollar figure as a regression, not a display bug.

### David Arutyunyan (`@davidarny`) — the feel of the glass

Eleven commits. Reduce Animations, translucent-card scroll performance, scrolling-update overhead, Z.ai credit quota limits. Where Robin ships surface area, David sands the 120 Hz path.

### The visitors

`@jal-co` folded the pi coding agent into Claude and Codex spend. `@iicdii` restored Cursor Enterprise included and on-demand usage. `@joshuavial` ranked profile-scoped Claude login above an inference-only env token. `@ricardoakrug` added Reset All Settings. `@manelpb` put a 30-second timeout on provider refresh so the spinner could not run forever. `@xuing` stopped the single-instance guard from trusting a stale LaunchServices snapshot. dependabot keeps Sparkle and PostHog current.

### liaomingxin — the fork chapter

Seven commits, all on 25 August 2026, all in `+0800`. Research notes for the Kimi Code usage API, the provider itself (OAuth against `~/.kimi-code/`, Session / Weekly / Booster), a bezier crescent icon because the SVG parser rejects arc commands, a personal GitHub Actions DMG workflow that needs no Developer ID secrets, and `FORK.md`. The tag `v0.7.10-kimi.1` is deliberately namespaced so it can never collide with upstream `v0.7.x`.

## Seasonal Patterns

There are no holidays in this dataset. There are **release seasons**.

**June 15–27 — the sixteen-beta gauntlet.**  
`v0.7.0-beta.2` through `beta.16`, often one or two a day. The rewrite launched requiring macOS 26 Tahoe; four days later Sequoia came back (`feat(platform): support macOS 15 (Sequoia)+`). CI fought Xcode 26.5's broken `actool` (FB20183399) by pinning 26.4.1 and shipping a prebuilt `.icns`. The popover became a key-capable `NSPanel`. Liquid Glass landed, then grew an opaque body so text stayed readable. Antigravity joined the original five (Claude, Codex, Cursor, Devin, Grok). PostHog crash reporting and opt-out analytics arrived the day before stable. `v0.7.0` on 27 June is marketed as “a brand-new OpenUsage.”

**June 27 – July 2 — provider explosion (`v0.7.1`).**  
Copilot, OpenRouter, Z.ai. Share-as-image cards. Customize rebuilt as list → detail. Quota pace notifications. Cursor spend turned back on with unknown-model warnings. Homebrew documented. A strict issue-first PR gate (`CONTRIBUTING.md`) so the new inbound volume cannot melt the design.

**July 2–6 — becoming native (`v0.7.2`–`v0.7.3`).**  
The cultural turn: `feat(spend): native log scanners + dynamic model pricing, drop ccusage`. Spend tiles no longer shell out to a Node/Bun CLI. First-run detection enables whatever is already signed in. New providers added by an update are credential-probed instead of silently ignored. Customize becomes the primary footer button.

**July 6–12 — the split week (`v0.7.4`).**  
OpenCode (Zen/Go). A cross-provider Total Spend ring. Hover breakdowns. And then the 8 July flood: extract panel height, outside-click monitor, popover footer, top bar, dashboard content, layout bootstrap, layout persistence; split `DashboardView`, `StatusItemController`, `WidgetDataStore`, `LayoutStore`. This is AGENTS.md's “keep files under ~500 LOC” becoming a merge train.

**July 13–16 — product, not just meters (`v0.7.5`–`v0.7.6`).**  
Claim a Codex rate-limit reset from the popover. iCloud usage-history sync across Macs. A machine-readable `openusage` CLI and `/v1/limits`. Claude Desktop as a read-only login fallback. Hide menu-bar numbers while the screen is shared. A ~20× Codex spend inflation from subagent replay logs gets fixed in public.

**July 19 – August 11 — the pause and the revert.**  
`v0.7.7-beta.1` ships Account-first Phase 0 and 1 (shell-environment snapshot, account registry, cache stamp). Phase 2 and 2b (Claude multi-account from custom config dirs, one name resolver) land, soak, and then — 11 August, `cd3dec0` — **are reverted ahead of `v0.7.8`**. The plan in `docs/research/account-first-plan.md` remains; the cards on users' machines do not grow extra Claudes yet. Reduce Animations and Reset All Settings do ship.

**August 13–24 — chase the models (`v0.7.9`, `v0.7.10-beta.*`).**  
OpenCode Go meters move to the official usage API. Cursor Grok 4.6, Grok Bot usage, Gemini 3.7 Flash slugs, GPT-5.6 rate refresh. The hottest ongoing theme is no longer “add a provider”; it is “the vendor renamed a slug yesterday.”

**August 25 — the fork.**  
This checkout stops being a pure upstream mirror. Kimi Code becomes an eleventh provider. Personal DMGs go out as `v*-kimi.N`.

Wednesday is the busiest weekday (130 commits); Thursday–Sunday are quieter. That matches a maintainer who batches agent PRs mid-week and cuts tags around then.

## The Great Themes

### 1. Leave the web runtime behind

The first month of `main` is a controlled demolition of the Tauri stack. Logging is ported. The LaunchAgent leftover is deleted on launch. The updater manifest is preserved so 0.6.x users can still reach `v0.6.28`. Then ccusage — the last Node-shaped dependency in the spend path — is replaced by `IncrementalJSONLScanner` and `Sources/OpenUsage/Pricing/`. The README's promise becomes literal: no Node.js required.

### 2. Providers as a plugin protocol, vendors as weather

The rewrite started with five folders. Antigravity, Copilot, OpenRouter, Z.ai, OpenCode, then (on this fork) Kimi, each following the same auth → client → mapper shape. `DefaultLayout.swift` (33 edits) and `ProviderCatalog.swift` are the merge-conflict capitals, because every new meter needs four owner-approved defaults: enabled, Always Visible vs On Demand, pinned, order.

The other half of provider work is not adding cards. It is **keeping the numbers true** while Claude, Cursor, Codex, and Grok change plan windows, model slugs, and protobuf encodings out from under the app. `ClaudeProvider.swift`, `CodexProvider.swift`, and `CursorProvider.swift` sit in the top-changed files for a reason.

### 3. Pricing as a live service

After ccusage died, pricing became its own product: a gh-pages supplement that installed apps fetch without a release, plus bundled snapshots regenerated at ship time. Hourly refresh replaced daily. Alias rules accumulate (`grok-4.5-fast-high`, dashed `grok-4-6`, `grok-proxy` → Grok Build, Codex auto-review → GPT-5.6 Luna). `@validatedev` and Robin ping-pong here. A warning triangle on a spend tile is a product incident.

### 4. Native Mac, not a web popover wearing a tray icon

NSPanel instead of NSPopover. Liquid Glass with a single fallback file. Coordinated-morph auto-resize. Screen-share privacy for the menu-bar strip. Sparkle windows forced to the foreground for a dockless app. Party/Drunk easter eggs behind a secret code. The UI files `DashboardView.swift` and `docs/dashboard.md` are tied for the most-edited path (48 each) — behavior and documentation are supposed to move together.

### 5. Agents writing, humans releasing

The 1,638 commits across all refs are mostly agent worktrees that never squash onto `main` in one piece. What does land is reviewed, changelogged, and tagged by Robin, with a release skill that refuses blank notes and draft GitHub releases. Version numbers are a human decision; AGENTS.md forbids agents from bumping them on their own.

### 6. A small surface, a high gate

`CONTRIBUTING.md` is unusually frank: most external PRs are closed by design. Scope is “tracking AI coding subscription usage, nothing more.” Combined with file-size splits and a test file for almost every behavior, the repo feels like a studio product that happens to be MIT, not a bazaar.

## Plot Twists and Turning Points

1. **The rewrite is a squash, not a history.** `53bc2f0` is the Swift app fully formed. You cannot `git blame` a Tauri component across the cut. `v0.6.28` is tagged on the same calendar week as `v0.7.0-beta.16` so the old updater still has a final landing pad.

2. **Tahoe-only lasted four days.** The native edition originally targeted macOS 26. Sequoia support landed as `051ba2f` before the first stable. Liquid Glass is capability-gated rather than version-gated in the views.

3. **ccusage was supposed to be the spend engine.** It was patched through June (runner resolution, nvm aliases, snapshot cache) and then deleted in `v0.7.3`. That single PR created the `Pricing/` tree and made model prices a hot-updated artifact.

4. **Account-first is the unfinished novel.** PR #1014 (location-keyed default card vs identity-keyed extras) was abandoned as structurally flawed. A new plan (`docs/research/account-first-plan.md`) ships Phase 0–1, then Phase 2/2b, then **reverts 2/2b before `v0.7.8`** so a release does not contain half a multi-account world. Phase 1's registry remains. Extra Claude homes do not.

5. **Codex spend was ~20× too high.** Subagent replay logs were counted as new tokens (`#1001`). Trust in local-log spend had to be earned twice: once by going native, once by filtering the logs the CLIs actually write.

6. **The 8 July extract train.** Ninety-plus commits in a day, almost none user-visible. That is the cost of the LOC cap and of letting Codex/Claude agents open one PR per split.

7. **July's silence.** After `v0.7.7-beta.1` (19 July) the firehose stops for three weeks. `v0.7.8` on 11 August is a consolidation release: revert, settings resets, animation reduction, pricing. Growth gives way to not shipping a broken identity model.

8. **This directory is a fork as of today.** Upstream cannot sign a Sparkle build for liaomingxin. The personal workflow uses ad-hoc signing and `v*-kimi.*` tags, and keeps the official bundle id so settings and keychain survive replacing the official app.

## The Current Chapter

`main` here is upstream `v0.7.10-beta.2` plus Kimi.

The product is a mature menu-bar dashboard: eleven providers in this tree, native spend, iCloud history, a CLI, a loopback API, Sparkle, Homebrew (upstream), and a Customize surface that is now the product's second home. The code is larger than the rewrite (385 Swift files vs 116) but more partitioned; tests grew faster than production files.

The live tensions are the same ones the history already named:

- **Vendors move.** Pricing aliases and quota windows will keep generating the next `fix(pricing):` and `fix(cursor):` commits.
- **Multi-account is designed, not shipped.** Phase 2 will have to re-land without the location/identity split that killed #1014.
- **Bus factor.** One human cuts every release. Agents multiply throughput; they do not replace the changelog, the version number, or the “does this feel like OpenUsage?” veto.
- **Fork vs upstream.** Kimi is good enough to PR (`FORK.md` says so). Until it is accepted, every `git merge upstream/main` will touch `DefaultLayout.swift` and `ProviderCatalog.swift`.

Seventy-two days, 546 commits, a complete platform change, and a menu-bar app that still does one job. That is the story so far.
