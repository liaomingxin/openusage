# Local Agent Subscription Rollup

Execution checklist for folding this Mac's agent logs into the subscription card they actually
billed, and for showing cache read, cache write, and cache hit rate on the local spend rows.

This is a working plan, not user-facing behavior docs. Update `docs/providers/` and
`docs/dashboard.md` only when the task that changes that behavior is done.

Do not mark a task complete in this file, or in the session todo list, until its **Done when**
check has passed. Finish one task before starting the next. A compile, a focused test, or a
fixture assertion is the check — not "the code looks right."

## Decisions already made

- Official login only. A row counts when the agent billed **that provider's own host**, whether
  the login is a subscription OAuth or that provider's own API key.
- Unknown gateways stay out. Do not fold `cliproxy-openai`, `02yidyidayidao-openai`, `bmw888`,
  `6688ai.xyz`, `127.0.0.1`, Hermes `custom`, or any provider id that is not on the allowlist.
- Do not guess from the model name. Hermes `claude-opus` on `6688ai.xyz` is not Claude.
- Qoder and Copilot CLI are out. Pi `github-copilot` is out with them.
- Pi `cursor` and Pi `google-antigravity` are out. Cursor's headline is the account CSV.
  Antigravity's own conversation databases are already scanned. Folding Pi on top risks
  counting the same work twice.
- Account Trend, Lifetime Tokens, Day Streak, and Threads stay Codex account-API rows. They
  have no cache fields. Do not add cache math to them.
- No new cache metric, and nothing new on the menu bar. Cache read, cache write, and hit rate
  appear on the existing Today / Yesterday / Last 30 Days hover.
- Kimi has no local spend rows today. Add `kimi.today`, `kimi.yesterday`, and `kimi.last30`
  only. Enabled, On Demand (below the caret), not pinned. No Kimi Usage Trend in this pass.
  These rows use `WidgetDescriptor.spendTiles`, so Kimi joins Total Spend once they exist.
- Z.ai and Cursor headlines stay the server numbers. Local agent rows do not add into those
  totals, into their model-share list, or into Total Spend. They render as a separate
  **This Mac** block in the hover, with their own source note.
- Claude, Codex, and Grok headlines are local logs. Official Pi / OpenCode / Hermes traffic
  for those providers **is** added to the headline. Say so in the source note.
- Agent Usage stays a per-tool view, including proxy traffic. It is not added to Total Spend.
- No fuzzy dedup across agents. Pi and OpenCode do not share message ids. Dedupe only inside
  one source, the way those scanners already do.
- Old snapshots and iCloud history must still decode. New cache fields are optional.

## Hit rate

```text
prompt = uncached input + cache write + cache read
hit rate = cache read / prompt
```

Output and reasoning are not in the denominator. If the source did not report cache, leave the
rate blank. Do not print 0%.

ZCode's `input_tokens` already includes cache read. Before storing:

```text
net input = max(0, input_tokens - cache_read - cache_write)
displayed total = computed_total_tokens
```

A rate above 100% means this subtraction was skipped.

## Where each local source goes

| Source | Ledger | Card | Headline |
|---|---|---|---|
| Pi `anthropic`, `claude-agent-sdk` | already folded | Claude | already added |
| Pi `openai-codex` | already folded | Codex | already added |
| Pi `xai` | `~/.pi/agent/sessions` | Grok | add |
| Pi `kimi-coding` | same | Kimi | add (new rows) |
| Pi `zai`, `zhipu`, `zai-coding-cn` | same | Z.ai | This Mac only |
| OpenCode `openai` OAuth, cost 0 | already folded | Codex | already added |
| OpenCode `openai` API key | `opencode*.db` | Codex | add |
| OpenCode `xai` on xAI's own host | same | Grok | add |
| OpenCode `zai-coding-plan` | same | Z.ai | This Mac only |
| OpenCode `kimi-for-coding`, `moonshotai-cn` on Kimi's own host | same | Kimi | add |
| OpenCode `opencode`, `opencode-go` | already on the OpenCode card | OpenCode | unchanged |
| ZCode `model_usage` where `provider_id` contains `bigmodel` | `~/.zcode/cli/db/db.sqlite` | Z.ai | This Mac only |
| Kimi Code CLI events | `~/.kimi-code/server/events/session_*.jsonl` | Kimi | add |
| Hermes `openai-codex` and host contains `chatgpt.com/backend-api/codex` | `~/.hermes/state.db` `session_model_usage` | Codex | add |
| Hermes `zai` and host contains `api.z.ai` | same | Z.ai | This Mac only |
| Cursor CSV | already the Cursor headline | Cursor | do not add; surface the cache columns the parser already reads |
| Antigravity app, IDE, `agy` | already scanned under `~/.gemini/antigravity*` | Antigravity | unchanged |

Completed ZCode rows only. Error and cancelled rows are zero and stay out.

## This Mac block

Z.ai's Today / Yesterday / Last 30 Days totals and their model shares stay whatever
`model-usage` / `usage-detail` returned. Under that list, a second list shows only the local
agent rows for that period: model, tokens, cache read, cache write, hit rate. The source note
names the agents that contributed (ZCode, Pi, OpenCode, Hermes). The block is omitted when
this Mac has no local rows. It must not change the row's dollar or token total.

Cursor does not get a This Mac block. Its CSV is already account-wide and already has
`Cache Read` and `Input (w/ Cache Write)`. Put those buckets on the existing model rows.

## Tasks

### 1. Keep cache buckets on the spend history

Done. `DailyUsageAccumulatorTests` passed on 2026-09-22.

Files: `DailyUsageSeries.swift`, `DailyUsageAccumulator.swift`, `SpendTileMapper.swift`,
`ProviderUsageHistory`.

`ModelUsageEntry` gains optional `inputTokens`, `cacheReadTokens`, and `cacheWriteTokens`.
Nil means the source did not report cache. Zero means it reported zero. The day total's
`totalTokens` and `costUSD` stay exactly what they are today.

`DailyUsageAccumulator.add` takes an optional `TokenBreakdown`. `merged()` sums buckets only
across entries that have them. One nil bucket in a merge stays nil for that field rather than
becoming zero.

Done when: a unit test adds two priced rows, one with cache and one without, and the merged
scan keeps the cached row's read/write, leaves the other nil, and does not change the
existing token or cost totals.

### 2. Attribution allowlist

Done. `SubscriptionAttributionTests` passed on 2026-09-22.

### 3. Thread buckets through scanners that already have them

Done. Claude, Codex, Grok, Pi, OpenCode's Codex slice, and Cursor CSV now keep cache buckets.
Existing token and cost assertions still pass.

Those scanners now pass `TokenBreakdown` into `DailyUsageAccumulator.add`. Which rows are
counted did not change. Fixtures assert a reported cache bucket, and the old token and cost
figures still match.

### 4. Fold the missing Pi providers

Done. `zai-coding-cn`, `kimi-coding`, and `xai` map to Z.ai, Kimi, and Grok. Z.ai stores Pi rows on `thisMacSeries` and does not change the headline.

### 5. OpenCode official API-key rows

Done. `OpenCodeSubscriptionUsageScannerTests` passed. Zero-cost OAuth stays on the old scanner. Positive-cost `openai` is priced with Codex rates. `zai-coding-plan` is This Mac. `cliproxy-openai` is dropped.

### 6. ZCode scanner

Done. `ZCodeUsageScannerTests` passed. Completed BigModel rows only. Net input subtracts cache. Hit rate stays at or under 100%.

### 7. Kimi CLI local spend

Done. `KimiCLIUsageScannerTests` and `KimiLayoutTests` passed. `kimi.today`, `kimi.yesterday`, and `kimi.last30` are On Demand and not pinned.

### 8. Hermes official hosts

Done. `testOfficialSlicesKeepZAIAndCodexAndDropProxies` passed. The unfiltered Agent scan still parses all four rows. Codex and Z.ai consume only the official slices.

### 9. Hover

Done. `CacheHoverTests` passed. A reported cache row gets a caption. A nil-cache row does not. A Z.ai breakdown keeps its headline token total after This Mac rows are attached.

### 10. Docs

Done. Claude, Codex, Grok, Z.ai, Kimi, Cursor, the dashboard, and usage history describe the shipped paths. They do not claim Qoder, Copilot CLI, MiniMax, or proxy traffic is included.

## Explicitly not in this pass

MiniMax Code app and `mcode` have no model ledger. Kimi.app and KimiCU have no usage
database. Trae's agent database is not SQLite. Lingma's `token_count` is memory size.
Kiro stores credits, not token buckets. Factory / Droid sessions have no stable usage
object. Qwen, CodeBuddy, Augment, OpenClaude, the ChatGPT app, the Gemini app, and Grok
Bot have no coding-session token ledger. Revisit one of these only after its ledger is
found. Do not estimate tokens from transcript text.
