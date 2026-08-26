# What Extra Account Data Each Provider Exposes

Availability survey of the **account and usage information OpenUsage could show
but doesn't** — beyond today's rows and beyond the renewal date already covered
by `docs/research/subscription-expiry.md`. Done 2026-08-26/27. No
implementation; this is the "what's on the table" doc behind a possible next
round of rows.

**Benchmark.** Z.ai got genuinely richer in `3d983f9` — daily token totals, a
usage trend and MCP tool-call counts. The question for every other provider is:
*what is the Z.ai-grade data we are leaving on the table?*

**Method.** For each provider: read its auth store, usage client and mapper and
list exactly what OpenUsage renders today; then diff that against the **full
live response bodies** for the calls the app already makes (the cheapest wins
live there — a discarded field costs zero extra requests); then look for extra
endpoints reachable with the *same* credential by reading the provider's own
installed CLI (`claude`, `codex`, `grok`, `agy`, `kimi`, `cursor-agent`) and its
JS bundles; then live-verify with read-only calls using the real local
credentials.

**Safety.** Read-only throughout. Every call was a GET, except Cursor's Connect
RPCs (POST is that API's only verb, and only `Get*` methods were called — never
`Set*`/`Create*`/`Enable*`/`Transfer*`) which is the same shape the app already
uses. No token was refreshed or rotated. Nothing that claims, consumes,
purchases or resets was called — in particular Codex's
`rate-limit-reset-credits/consume`, Claude's `overage_credit_grant` /
`create_api_key` / `pro_trial`, Cursor's `EnableOnDemandSpend` /
`SetSpendLimitPolicy`, and Codex's `wham/accounts/send_add_credits_nudge_email`
(which sends mail) were deliberately left alone. claude-swap's stashed keychain
tokens were not touched at all. Every account UUID, org UUID, e-mail, customer
id, user id and token below is redacted; no secret was written to this doc, a
scratch file, or a commit.

---

## TL;DR

| Provider | Best extra data available | Already fetched, or new endpoint? | Verdict |
|---|---|---|---|
| **Codex** | Account-wide **daily + weekly token history** (~2 months), lifetime tokens, day streak, thread count, top skills/plugins | **new endpoint** — `GET /backend-api/wham/profiles/me` | **worth shipping** — the one true Z.ai-grade win |
| **Grok** | **Per-product split of the weekly pool** (`GrokBuild` 4%, `GrokChat` 1%, `GrokImagine`, `GrokAppBuilder`) | already fetched — `/v1/billing?format=credits` → `productUsage[]`, dropped entirely | **worth shipping** — free |
| **Z.ai** | **Raw credit counts** behind the two % meters (`1,168 / 28,000` used), and a **named per-MCP-tool breakdown** | already fetched — quota `usage`/`currentValue`/`remaining`; tool-usage `toolSummaryList[]` | **worth shipping** — free |
| **Claude** | **Which limit is actually binding** (`limits[].is_active`) + Anthropic's own `severity` | already fetched — `/api/oauth/usage` → `limits[]`, both fields dropped | **worth shipping** — free |
| **Cursor** | **Payment-failure / dunning warning** (`lastPaymentFailed`, `paymentRecoveryAction`) | already fetched — `/api/auth/stripe`, only `customerBalance` is read | **worth shipping** — free |
| **Codex** | Second hidden meter: the **`gpt-reserve`** weekly window (`additional_rate_limits[1]`) | already fetched — `/wham/usage`, only the Spark entry is mapped | **worth shipping** — free |
| **Claude** | **Prepaid credit balance** + monthly credit-purchase cap and its reset | **new endpoints** — `/api/oauth/organizations/<org>/prepaid/credits` and `…/prepaid/bundles` | **worth shipping** for credit buyers, but +1–2 requests and org-scoped |
| **Cursor** | Cursor's **own** per-model token + cost aggregates, and per-day/per-model tokens | **new RPCs** — `GetAggregatedUsageEvents`, `GetDailySpendByCategory` | **marginal** — same data the CSV already gives, but cheaper and authoritative |
| **Kimi Code** | Parallel-agent cap (`parallel.limit: 30`); account level/name from `/coding/v1/me` | already fetched (`usages`) / new endpoint (`me`) | **marginal** — a static number and account trivia |
| **Antigravity** | Nothing found | — | **unavailable** (and not live re-verified — see below) |

Two structural notes worth carrying forward:

- The cheapest wins really are inside responses we already fetch. Five of the
  nine rows above cost **zero extra network calls**.
- Only Codex has a genuinely new *class* of data (account-wide history). For
  everything else the gap is breakdown and framing, not raw availability.

---

## Codex — the biggest win, and it's a new endpoint

### What OpenUsage renders today

Session, Weekly, Spark, Spark Weekly, Extra Usage (credits), Rate Limit Resets,
Usage Trend, Today / Yesterday / Last 30 Days, Renews. The trend and spend
tiles are **machine-local and estimated** — scanned from `~/.codex` logs and
priced through the pricing engine (`exportingHistory(scope: .machineLocal,
estimatedCost: true)`).

### Already fetched and thrown away — `GET /backend-api/wham/usage`

```json
{
  "user_id": "<redacted>", "account_id": "<redacted>", "email": "<redacted>",
  "plan_type": "pro",
  "rate_limit": { "allowed": true, "limit_reached": false,
    "primary_window": { "used_percent": 5, "limit_window_seconds": 604800,
                        "reset_after_seconds": 493526, "reset_at": 1788272713 },
    "secondary_window": null },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
      "rate_limit": { "primary_window": {…5h…}, "secondary_window": {…weekly…} } },
    { "limit_name": "gpt-reserve", "metered_feature": "base_model_inference",
      "rate_limit": { "primary_window": { "used_percent": 0,
                        "limit_window_seconds": 604800, "reset_at": 1788383988 },
                      "secondary_window": null } }
  ],
  "credits": { "has_credits": false, "unlimited": false,
               "overage_limit_reached": false, "balance": "0",
               "approx_local_messages": [0, 0], "approx_cloud_messages": [0, 0] },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null, "promo": null,
  "rate_limit_reset_credits": { "available_count": 1, "applicable_available_count": 0 }
}
```

Dropped, in descending order of usefulness:

- **`additional_rate_limits[1]` — the `gpt-reserve` weekly window.**
  `CodexUsageMapper.sparkLines` matches `"spark"` in `limit_name` /
  `metered_feature` and returns early, so every *other* additional limit is
  discarded. On this account `gpt-reserve` (`base_model_inference`) is a real
  second weekly meter at 0%. Generalizing the matcher into "one meter pair per
  additional limit" is a small, free change.
- **`credits.approx_local_messages` / `approx_cloud_messages`** — a
  `[low, high]` range of how many more messages the remaining credit balance
  buys. Both `[0, 0]` here because the balance is 0; on an account with credits
  this is a much friendlier number than "821 credits".
- `credits.unlimited`, `credits.overage_limit_reached`,
  `spend_control.{reached, individual_limit}` — spend-cap state; would make a
  "you've hit your spend limit" warning possible without guessing.
- `rate_limit.limit_reached` / `allowed`, `rate_limit_reached_type` — an
  explicit "you are currently blocked" flag we today only infer from 100%.
- `code_review_rate_limit` — null here; a separate meter on accounts that use
  Codex code review.
- `rate_limit_reset_credits.applicable_available_count` (0) vs
  `available_count` (1) — how many of the credits apply to the *current* block.
  `CodexResetClaimService` could use this to grey out a useless claim.
- `promo` — null here.

### The new endpoint: `GET /backend-api/wham/profiles/me` — **live-verified**

```
GET https://chatgpt.com/backend-api/wham/profiles/me
Authorization: Bearer <access token from ~/.codex/auth.json>
ChatGPT-Account-Id: <account id>
```

(Works with just those two headers — the `OpenAI-Beta: codex-1` /
`originator: Codex Desktop` pair the reset-credits call sends is not required.
Response is ~9 KB.)

```json
{
  "profile": { "username": "<redacted>", "display_name": "<redacted>",
               "profile_picture_url": "<redacted>" },
  "stats": {
    "lifetime_tokens": 1588515077,
    "peak_daily_tokens": 208441148,
    "current_streak_days": 11,
    "longest_streak_days": 11,
    "total_threads": 514,
    "longest_running_turn_sec": 5373,
    "fast_mode_usage_percentage": 63.92,
    "total_skills_used": 322,
    "unique_skills_used": 58,
    "most_used_reasoning_effort": "xhigh",
    "most_used_reasoning_effort_percentage": 41.45,
    "daily_usage_buckets":            [ { "start_date": "2026-06-26", "tokens": 1737922 }, … ],
    "cumulative_daily_usage_buckets": [ { "start_date": "2026-06-26", "tokens": 1737922 }, … ],
    "weekly_usage_buckets":           [ { "start_date": "2026-06-22", "tokens": 1737922 }, … ],
    "top_invocations": [
      { "type": "skill",  "skill_name": "<redacted>",  "usage_count": 51 },
      { "type": "plugin", "plugin_name": "<redacted>", "usage_count": 27 }, … ],
    "workspace_rank": null, "workspace_total_user_count": null
  },
  "metadata": { "stats_as_of": "2026-08-26",
                "generated_at": "2026-08-26T21:20:01Z", "stats_error": null }
}
```

**Why this matters.** OpenUsage's Codex trend is scanned from local JSONL and
priced by estimate. This is **OpenAI's own account-wide token count**, covering
every machine the user codes on — the same class as Cursor's `.accountWide` CSV
history and Z.ai's `.accountWide` model usage. 39 daily buckets spanning
2026-06-26 → 2026-08-26 on this account, plus 10 weekly buckets.

**Honest limits.**

- **Tokens only, no cost.** There is no dollar figure anywhere in the payload,
  so this can feed a token trend but not the spend tiles.
- **Sparse buckets.** Only days with usage appear (39 buckets over ~62 days) —
  a consumer must treat a missing day as zero, not as a gap.
- **Stale by up to a day.** `stats_as_of: 2026-08-26` with `generated_at` the
  same evening: this is a batch rollup, not live. Today's tokens are not in it.
  A trend fed from here would always lag the local scanner by ~1 day, which
  argues for *adding* a row rather than replacing the local one.
- **~2 months of history**, start date not configurable — no parameters are
  accepted.
- **Undocumented**, in the same `wham/*` namespace the Codex CLI uses (so it
  shares the CLI's de-facto stability, which is what the app already relies on
  for `wham/usage`).
- **Per-account**, not per-org. `workspace_rank` /
  `workspace_total_user_count` are null on a personal Pro account; they would
  presumably populate on a workspace seat, which was not verifiable here.
- It carries `username`, `display_name` and an avatar URL. Those are identity,
  not usage — read the `stats` block and nothing else.

### `POST /backend-api/wham/usage/thread_usage/query` — **not verified, on purpose**

Present in the `codex` binary's route table and in
`backend-client/src/client/thread_usage.rs` / `tui/src/status/thread_usage.rs`.
Its response types are `ThreadUsageQueryResponse { … }` → `ThreadUsage` with
**`estimated_usage_usd_micros`**, `estimated_usage_credits_micros` and `groups`,
where `ThreadUsageBreakdownGroup` carries `speed`, `net_new_input_tokens`,
`total_tokens`.

That is **OpenAI's own dollar estimate per thread** — exactly what OpenUsage
today imputes from local logs via the pricing engine. A GET returns
`405 Method Not Allowed`, i.e. it is POST-only, so under this survey's
GET-only rule it was **not called**. Verifying it needs one deliberately
approved POST with a thread-id filter body; worth doing before anyone plans
work on it.

### Other Codex routes checked

| Call | Result |
|---|---|
| `GET /wham/settings/user` | 200 — CLI preferences (`git_diff_mode`, `branch_format`, review prefs). No usage. |
| `GET /wham/tasks/list` | 200 — `{"items": [], "cursor": null}`. Codex Cloud tasks; empty here, and not a usage number. |
| `GET /wham/usage/thread_usage/query` | 405 (POST-only, see above) |
| `GET /wham/config/bundle` | 400 `No active workspace` (from the prior survey) |
| `/backend-api/{me, accounts/check/*, subscriptions}` | 403 Cloudflare challenge (prior survey) |
| `wham/accounts/send_add_credits_nudge_email` | **not called** — it sends e-mail |
| `wham/{environments, remote/control/*, workspace-messages, agent-identities/jwks}` | Cloud/remote plumbing, no usage numbers |

Full route inventory came from `strings` over the `codex` Rust binary
(`@openai/codex-darwin-arm64`).

---

## Grok — a free per-product breakdown we already download

### What OpenUsage renders today

Weekly limit, Extra Usage badge (pay-as-you-go cap), Usage Trend + spend tiles
(local, estimated). Plan name from `/v1/settings`.

### Already fetched and thrown away — `GET /v1/billing?format=credits`

```json
{ "config": {
    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                       "start": "2026-08-23T15:36:17Z", "end": "2026-08-30T15:36:17Z" },
    "creditUsagePercent": 5.0,
    "onDemandCap": { "val": 0 },
    "onDemandUsed": { "val": 0 },
    "productUsage": [ { "product": "GrokBuild", "usagePercent": 4.0 },
                      { "product": "GrokChat",  "usagePercent": 1.0 },
                      { "product": "GrokAppBuilder" },
                      { "product": "GrokImagine" } ],
    "isUnifiedBillingUser": true,
    "prepaidBalance": { "val": 0 },
    "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
    "billingPeriodStart": "2026-08-23T15:36:17Z",
    "billingPeriodEnd": "2026-08-30T15:36:17Z" } }
```

`GrokCreditsConfigDecoder` reads exactly four things — `currentPeriod.type`,
`creditUsagePercent`, `currentPeriod.start/end`, `onDemandCap.val` — and drops
the rest.

- **`productUsage[]` is the win.** It splits the single weekly pool percent by
  product: GrokBuild (the CLI) 4%, GrokChat 1%, and two products at 0
  (proto-JSON omits zero, so a missing `usagePercent` means 0). This answers
  "what is eating my Grok week", which the one bare Weekly bar cannot. It is
  free: same response, same request.
- **`onDemandUsed`** — pay-as-you-go actually spent, next to the cap the badge
  already shows. Turns the badge into a real meter ("$0 of $25 used").
- **`prepaidBalance`** — a credit balance row, like Cursor's Credits.
- `topUpMethod`, `isUnifiedBillingUser` — account plumbing, low value.

### The other Grok call — `GET /v1/billing` (no `format`), a **new** request

```json
{ "config": { "monthlyLimit": {"val":0}, "used": {"val":0}, "onDemandCap": {"val":0},
    "billingPeriodStart": "2026-08-01T00:00:00Z",
    "billingPeriodEnd":   "2026-09-01T00:00:00Z",
    "history": [ { "billingCycle": {"year":2026,"month":7},
                   "includedUsed": {"val":0}, "onDemandUsed": {"val":0},
                   "totalUsed": {"val":0} }, …3 months… ] } }
```

A three-month calendar rollup of API-credit spend. All zeros on this account
(a unified-billing subscription user spends from the weekly pool, not from
credits), so it is **unverifiable whether `history` ever carries a non-zero
number for a subscriber**. Costs one extra request per refresh for what may
always be zeros — not recommended.

### Other Grok surfaces checked

`GET /v1/settings` (200) is a 90-key CLI-config blob; besides
`subscription_tier_display` (already used as the plan name) the only vaguely
relevant keys are `on_demand_enabled`, `usage_billing_redirect_url` (null) and
`subscription_watch_interval_secs` (60 — Grok's own polling cadence, a hint but
not data). `GET /v1/user` (200) is pure identity plus `teamId`/`organizationId`
(both null here) and `hasGrokCodeAccess`. `strings` over `grok` 1.0.5 shows the
CLI's whole remote surface is `/v1/{settings,billing,models,chat/completions}`
plus the Cloudflare-gated `accounts.x.ai` paywall probe — there is nothing else
to find.

---

## Z.ai — the benchmark, but two things are still on the floor

`3d983f9` already shipped daily tokens, the trend, MCP tool counts and the
period rows; `d4500a1` shipped the renewal date. What remains:

### 1. Raw credit counts behind the percent meters — `GET /api/monitor/usage/quota/limit`

```json
{ "code": 200, "data": { "limits": [
      { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
        "usage": 28000, "currentValue": 1168, "remaining": 26831,
        "percentage": 4, "nextResetTime": 1787782033933 },
      { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
        "usage": 140000, "currentValue": 1612, "remaining": 138387,
        "percentage": 1, "nextResetTime": 1788075596997 } ],
    "level": "max" }, "success": true }
```

`ZAIUsageMapper` reads `percentage` and turns each entry into a
`limit: 100` percent bar. **`usage` (the allowance), `currentValue` (used) and
`remaining` are dropped**, so the Session and Weekly rows can only ever say
"4%" where every other provider's bounded row can say "1,168 / 28,000". This is
free — same response, one mapper change — and it is the single most Z.ai-shaped
gap left.

(Note: this account's plan returns **no `TIME_LIMIT` entry**, so the shipped
`zai.webSearches` row is empty here. That's plan-dependent, not a bug.)

### 2. A named per-tool breakdown — `GET /api/monitor/usage/tool-usage`

`ZAIActivityMapper.parseToolUsage` reads only three scalars out of
`totalUsage` (`totalNetworkSearchCount`, `totalWebReadMcpCount`,
`totalZreadMcpCount`). The same body also carries:

```json
{ "data": {
    "granularity": "hourly",
    "x_time": [ "2026-08-24 05:00", … 73 buckets … ],
    "toolDataList": [ { "toolCode": "search-prime",
                        "toolName": "联网搜索 MCP", "toolNameI18n": "Web Search MCP",
                        "usageCount": [0,0,…,2,…], "totalUsageCount": 7 }, … ],
    "toolSummaryList": [ { "toolCode": "search-prime",
                           "toolNameI18n": "Web Search MCP",
                           "totalUsageCount": 7, "sortOrder": 1 }, … ],
    "totalUsage": { "toolDetails": …, "totalSearchMcpCount": …,
                    "totalNetworkSearchCount": …, "totalWebReadMcpCount": …,
                    "totalZreadMcpCount": … } } }
```

So the MCP Tools row could name each tool (`toolNameI18n` is already
English-localized) instead of summing three hardcoded counters, and could carry
a per-tool time series. Free.

### 3. Smaller drops

- `subscription/list[0]` also carries `initialPrice`, `standardPrice`,
  `actualPrice`, `renewPrice`, `billingCycle`, `autoRenew`, `paymentChannel`,
  `refundable`, `banStatus` / `banExpireTime`. The renewal row could gain a
  price/interval subtitle for free; `banStatus != 0` would justify a header
  warning.
- `quota/limit → data.level` (`"max"`) is a second plan-name source, currently
  taken from `subscription/list.productName`.
- `model-usage → granularity` ("hourly" vs daily) is inferred by the mapper
  from the label format; the server states it outright.

### What was **not** findable for Z.ai

Z.ai ships no CLI to reverse-engineer — the console is a login-gated SPA — so
endpoint discovery could not go beyond the four documented paths
(`/api/biz/subscription/list`, `/api/monitor/usage/{quota/limit, model-usage,
tool-usage}`). No blind path-guessing was done. If someone wants more Z.ai
surface, the honest next step is pulling the console's JS bundle, not guessing.

---

## Claude — free framing wins, plus a real credits balance behind a new endpoint

### What OpenUsage renders today

Session, Weekly, Fable, Sonnet, Extra Usage, Usage Trend + spend tiles (local,
estimated). Plan name from the stored `subscriptionType` / `rateLimitTier`.

### Already fetched and thrown away — `GET /api/oauth/usage`

```json
{
  "five_hour":  { "utilization": 21.0, "resets_at": "2026-08-26T22:49:59Z",
                  "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
  "seven_day":  { "utilization": 54.0, "resets_at": "2026-08-27T02:59:59Z", … },
  "seven_day_sonnet": null, "seven_day_opus": null, "seven_day_cowork": null,
  "nimbus_quill": { "utilization": 0.0, "resets_at": null, … },
  "extra_usage": { "is_enabled": true, "monthly_limit": 100, "used_credits": 0.0,
                   "utilization": null, "currency": "USD", "decimal_places": 2,
                   "disabled_reason": null, "user_disabled": false,
                   "spend_limit_reached": false, "credits_ever_enabled": true,
                   "daily": null, "weekly": null },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 21, "severity": "normal",
      "resets_at": "…", "scope": null,               "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 54, "severity": "normal",
      "resets_at": "…", "scope": null,               "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 87, "severity": "warning",
      "resets_at": "…", "scope": { "model": { "display_name": "Fable" } },
      "is_active": true } ],
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
             "limit": { "amount_minor": 100, "currency": "USD", "exponent": 2 },
             "percent": 0, "severity": "normal", "enabled": true,
             "cap": { "money": null, "credits": { "amount_minor": 100, "exponent": 2 } },
             "balance": null, "auto_reload": null,
             "can_purchase_credits": false, "can_toggle": false,
             "disclaimer": "Usage credits cover you when you hit your plan limits. …" },
  "member_dashboard_available": false
}
```

`ClaudeUsageMapper` reads `five_hour.utilization`, `seven_day.utilization`,
`seven_day_sonnet.utilization`, the `weekly_scoped` entry whose model display
name is `Fable`, and `extra_usage.{is_enabled, used_credits, monthly_limit}`.
Everything else is dropped. The useful drops:

- **`limits[].is_active`** — *which* limit is currently the binding one. Here
  Fable is at 87% with `is_active: true` while Session (21%) and Weekly (54%)
  are not. The dashboard today gives four equal-looking bars and no hint which
  one will actually stop you. This is the highest-value/lowest-cost Claude
  change in the whole survey.
- **`limits[].severity`** (`normal` / `warning`) — Anthropic's own thresholds,
  rather than OpenUsage picking its own colour cutoffs.
- **`limits[]` is the general form.** The mapper hardcodes "Fable" by display
  name; iterating `limits` where `kind == "weekly_scoped"` would pick up every
  model-scoped weekly window automatically, including ones Anthropic adds
  later. (`seven_day_opus`, `seven_day_cowork`, `seven_day_omelette`,
  `tangelo`, `iguana_necktie`, `omelette_promotional`, `cinder_cove`,
  `amber_ladder` are all null on this account — codenames for windows that
  aren't on this plan. `nimbus_quill` is present at 0% with a null
  `resets_at`.)
- **`*_dollars` on each window** (`limit_dollars`, `used_dollars`,
  `remaining_dollars`) — all null on this Max plan, but the field names say
  some plan somewhere reports usage windows in money. Worth a re-check on a
  different plan tier; nothing to render today.
- **`spend`** is a newer, self-describing money view of `extra_usage`
  (currency + exponent instead of bare cents) plus `balance`, `auto_reload`,
  `can_purchase_credits` and `can_toggle`. If the Extra Usage row is ever
  reworked, read `spend` rather than `extra_usage`.
- `extra_usage.spend_limit_reached` / `user_disabled` / `disabled_reason` —
  would let the Extra Usage row explain *why* it is inactive instead of just
  vanishing.
- `member_dashboard_available` (false) — a team/org feature flag.

### New endpoints — live-verified

Endpoint inventory from `strings` over `claude.exe` (the Claude Code bundle);
only GET-shaped, non-mutating routes were called.

**`GET /api/oauth/organizations/<org>/prepaid/credits` → 200**

```json
{ "amount": 0, "currency": "USD",
  "balance": { "money": null, "credits": { "amount_minor": 0, "exponent": 2 } },
  "balance_credits": 0,
  "auto_reload_settings": null,
  "pending_invoice_amount_cents": null,
  "last_paid_purchase_cents": null,
  "expiry_policy_months": null,
  "tranches": [], "promo_tranches": [], "next_expires_at": null }
```

A real **prepaid credit balance** for Claude — the equivalent of `cursor.credits`
and `codex.credits`, which Claude has never had a row for. Zero on this
account, so the populated shape (`tranches`, `next_expires_at`) is inferred
from the field names rather than observed. `next_expires_at` would drive an
expiry tooltip exactly like Codex's reset credits already do.

**`GET /api/oauth/organizations/<org>/prepaid/bundles` → 200**

```json
{ "bundles": [ { "id": "bundle_50",   "credit_minor_units": 5000,   "price_minor_units": 4500 },
               { "id": "bundle_250",  "credit_minor_units": 25000,  "price_minor_units": 20000 },
               { "id": "bundle_1000", "credit_minor_units": 100000, "price_minor_units": 70000 } ],
  "bundle_paid_this_month_minor_units": 0,
  "bundle_monthly_cap_minor_units": 200000,
  "purchases_reset_at": "2026-09-01T00:00:00Z",
  "currency": "USD", "stripe_product_id": "<redacted>", … }
```

`bundle_paid_this_month_minor_units` / `bundle_monthly_cap_minor_units` /
`purchases_reset_at` are a ready-made bounded-dollars meter: "credit purchases
$0 of $2,000 this month, resets Sep 1". The `bundles[]` price list itself is
store-front data OpenUsage has no use for.

**`GET /api/oauth/claude_cli/roles` → 200**

```json
{ "organization_uuid": "<redacted>", "organization_name": "<redacted>",
  "organization_role": "admin",
  "workspace_uuid": null, "workspace_name": null, "workspace_role": null }
```

Org/workspace role. Only interesting for the multi-account cards, which already
show org names from `/api/oauth/profile`.

**`GET /api/claude_cli/bootstrap` → 200** — feature flags (`cedar_lagoon`,
`cedar_basin: "2027-08-31"`), `additional_model_options` / `model_access` /
`org_model_default` (all null here), and an `oauth_account` block duplicating
`/api/oauth/profile`. No usage numbers.

**Costs of the prepaid rows.** Both prepaid calls need the **organization
UUID**, which today the app only reads inside `ClaudeUsageClient.verifyAccount`
and immediately discards. Shipping them means threading the org UUID through
the provider, and **+1 or +2 requests per refresh** on a provider that is
already rate-limit sensitive (`ClaudeUsageMapper.rateLimitedUsage` exists for a
reason). That is the main argument for treating them as opt-in / low-cadence
rather than default-on.

### Claude endpoints checked that gave nothing

| Call | Result |
|---|---|
| `GET /api/oauth/account/settings` | 200 — onboarding flags and dismissed-banner ids only |
| `GET /api/oauth/cri` | 404 |
| `GET /api/oauth/organizations/<org>/contracts/prepaid/credits` | 405 (not GET) |
| `GET /api/oauth/organizations/<org>/contracts/auto_reload_settings` | 405 (not GET) |
| `/api/oauth/organizations/<org>/{payment_method, billing/*, overage_spend_limit, validate}` | covered in `subscription-expiry.md` — card metadata, 404s and 405s |
| `/api/oauth/organizations/<org>/{overage_credit_grant, setup_overage_billing, claude_code/pro_trial, claude_cli/create_api_key}` | **not called** — mutating |
| `/api/oauth/organizations/<org>/{plugins/*, skills/*, mcp/connectors/*, plugin_ratings/*, referral/*, admin_requests/*}` | marketplace / referral / team-admin surfaces, no usage numbers |

There is **no account-wide usage history for Claude anywhere in the OAuth
surface** — the `/api/oauth/*` route list is complete and contains no history
endpoint. The claude.ai web app's own usage screen uses cookie-authenticated
`/api/organizations/...` routes, which `docs/privacy.md` puts out of bounds.

---

## Cursor — a free dunning warning, and a cheaper path to data we already have

### What OpenUsage renders today

Total Usage, Cursor Models, Other Models, Grok Bot, Extra Usage, Requests,
Credits, Usage Trend + spend tiles (account-wide, from the CSV export), Renews.

### Already fetched and thrown away

**`GET /api/auth/stripe`** — the mapper reads only `customerBalance`.

```json
{ "membershipType": "ultra", "paymentId": "<redacted>",
  "subscriptionStatus": "active",
  "lastPaymentFailed": false, "paymentRecoveryAction": null,
  "pendingCancellationDate": null, "isYearlyPlan": false,
  "isOnBillableAuto": true, "customerBalance": 0,
  "isTeamMember": false, "teamMembershipType": null,
  "individualMembershipType": "ultra",
  "verifiedStudent": false, "studentDiscountApplied": false,
  "isOnStudentPlan": false, "trialEligible": false,
  "trialLengthDays": 7, "trialWasCancelled": false }
```

- **`lastPaymentFailed` / `paymentRecoveryAction` / `subscriptionStatus`** —
  a dunning state. If a Cursor payment fails, the user's meters keep looking
  fine right up until access stops. `ProviderSnapshot.warning` already exists
  (Claude uses it for rate limiting, Z.ai for "no coding plan"); wiring these
  three fields into it is a handful of lines and costs nothing.
- `isYearlyPlan`, `isTeamMember`/`teamMembershipType`, `isOnBillableAuto` —
  plan-shape context for the renewal row (already noted in
  `subscription-expiry.md`).
- **Do not read** `paymentId` (`cus_…`) or any card metadata.

**`GET /api/usage-summary`** — `individualUsage.plan` also carries
`breakdown: { included, bonus, total }`. `bonus` is free provider credit Cursor
grants beyond what you paid for ("We work with model providers to give you free
usage beyond what you've purchased"). Splitting Total Usage into
included-vs-bonus is possible for free; whether it's *useful* is a judgement
call.

**`POST …/GetCurrentPeriodUsage`** — drops `remainingBonus` / `bonusTooltip`,
`displayThreshold`, `autoBucketModels` (the ~28 model slugs that count as
"Cursor Models" — could make the Cursor Models row's tooltip honest), and
Cursor's own phrasings `displayMessage` /
`autoModelSelectedDisplayMessage` / `namedModelSelectedDisplayMessage`
("You've used 13% of your included usage").

**`POST …/GetPlanInfo`** — drops `price` (`"$200/mo"`, carrying the interval in
plain text), `includedAmountCents` and `planOwner`
(`PLAN_OWNER_STRIPE` vs a team seat).

### New RPCs — live-verified

The Cursor dashboard API is Connect-RPC (POST is its only verb). Only `Get*`
methods were called, with `{}` or a date range. Method inventory from the
`cursor-agent` JS bundles.

**`GetAggregatedUsageEvents`** (`{teamId: 0, startDate, endDate}` — `teamId: 0`
works for an individual account):

```json
{ "aggregations": [
    { "modelIntent": "sand-default", "inputTokens": "12817453", "outputTokens": "1591510",
      "cacheReadTokens": "169491904", "totalCents": 22187.63, "tier": 1 },
    { "modelIntent": "claude-opus-5-thinking-high", "inputTokens": "1016381",
      "outputTokens": "899309", "cacheWriteTokens": "5977279",
      "cacheReadTokens": "94391590", "totalCents": 10590.84, "tier": 1 }, … 24 entries … ],
  "totalInputTokens": "47715236", "totalOutputTokens": "5101414",
  "totalCacheWriteTokens": "10829674", "totalCacheReadTokens": "634209835",
  "totalCostCents": 61413.48 }
```

**`GetDailySpendByCategory`** (`{periodStartMs, periodEndMs, groupBy:
"GROUP_BY_CATEGORY_MODEL"}`):

```json
{ "dailySpend": [ { "day": "1786579200000", "category": "cursor-grok-4.6-xhigh",
                    "totalTokens": "42825567" }, … ] }
```

(Response type also declares `spend_cents` per point and an
`effective_limit_cents`; `spend_cents` came back absent — i.e. 0 — on this
account, presumably because the usage was covered by included spend.)

Together these are a **JSON replacement for the ~30-day CSV export** the app
downloads today (`export-usage-events-csv`), with Cursor's **own** cost in
cents instead of OpenUsage's pricing-supplement imputation. That would remove
the CSV parser's exposure to column drift and make the Cursor spend tiles
authoritative rather than estimated — but it shows the user *the same numbers*.
Real engineering value, low user-visible value: **marginal** on the (value ÷
cost) ordering, though attractive if the CSV path ever breaks.

### Cursor RPCs that returned nothing useful

| RPC | Result |
|---|---|
| `GetCreditGrantsBalance` | `{}` (no grants on this account) |
| `GetMcpServerUsageSummary` | `{}` — request requires `team_scope` + `team_id`; team-only |
| `GetTokenUsage` | `{}` with an empty request |
| `GetMonthlyInvoice` | 200 but a placeholder period (`-2208988800000`) — needs parameters not derivable here |
| `GetCurrentBillingCycle` | 200 — same two epoch-ms bounds `usage-summary` already gives |
| `GetUsageLimitStatusAndActiveGrants` | 200 — `canConfigureSpendLimit`, `recommendedOnDemandLimitCents`, `onDemandMin/MaxCents`. Spend-limit *policy*, not usage |

A large share of the DashboardService surface (`GetTeamSpend`,
`GetOrgDailySpendByCategory`, `GetTeamAnalytics`, `GetOrganizationMembers`,
`ListInvoices`, `GetMemberRemovalInsights`, …) is **team/enterprise-only** and
unusable from a personal account — see `docs/research/cursor-enterprise-usage.md`.

---

## Kimi Code — thin, as expected

### What OpenUsage renders today

Session, Weekly, Booster. No trend, no spend tiles.

### Already fetched — `GET https://api.kimi.com/coding/v1/usages` (CN region)

```json
{ "user": { "userId": "<redacted>", "region": "REGION_CN",
            "membership": { "level": "LEVEL_ADVANCED" }, "businessId": "" },
  "usage": { "limit": "100", "used": "100", "resetTime": "2026-08-28T03:18:21Z" },
  "limits": [ { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
                "detail": { "limit": "100", "remaining": "100",
                            "resetTime": "2026-08-26T23:18:21Z" } } ],
  "parallel": { "limit": "30" }, "totalQuota": {},
  "authentication": { "method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING" },
  "subType": "TYPE_PURCHASE", "domain": "DOMAIN_NEXUS" }
```

Dropped: `parallel.limit` (the concurrent-request cap — a static badge, "30
parallel"), `subType`, `authentication.*`, `domain`, `totalQuota` (empty on
this account), and `limits[].detail.remaining`.

**One thing worth flagging while we're in here.** The 5-hour entry carries
`limit` and `remaining` but **no `used`**. `KimiUsageMapper.sessionLine` reads
`detail["used"]`, defaults it to 0, and renders `0%`. On this account
`remaining == limit`, so 0% happens to be right — but on a partially-consumed
window the Session bar would read 0% while the real figure is
`(limit - remaining) / limit`. This mirrors the Kimi CLI exactly (per
`docs/research/kimi-code-usage-api.md`: "the CLI reads `detail.used` and
`detail.limit` directly … It never computes `used = limit - remaining`"), so it
is a faithful port, not a typo — but it is worth confirming empirically whether
`used` ever appears, since a `remaining`-only payload makes the Session meter
useless.

### `GET /coding/v1/me` — a **new** endpoint, live-verified

```json
{ "user_id": "<redacted>", "global_id": "<redacted>", "nickname": "<redacted>",
  "avatar": "<redacted>", "phone": { "country_code": "<redacted>", "number": "<redacted>" },
  "status": "USER_STATUS_NORMAL", "region": "REGION_CN",
  "user_level": <redacted>, "user_level_name": "<redacted>",
  "domain": 1, "domain_name": "DOMAIN_NEXUS",
  "created_time": "2024-03-12T10:05:54Z",
  "last_login_time": "2026-08-22T15:16:20Z" }
```

Account trivia — level name, signup date, last login. It also returns a phone
number, so if this is ever called the mapper must read `user_level_name` and
nothing else. Not worth a request on its own.

**Limits.** Verified on the CN region (`~/.kimi-code/region` = `cn`, host
`api.kimi.com`); the global host is `api.kimi.ai` with the same shape. The Kimi
access token lives 15 minutes and refreshing **rotates the refresh token**, so
this verification used the already-valid stored token and never refreshed —
same discipline as the prior survey. `strings` over the `kimi` binary does not
embed the `coding/v1/*` paths as literals (they're built at runtime), so the
surface documented in `docs/research/kimi-code-usage-api.md` (`usages`, `me`)
remains the best inventory we have; `/coding/v1/{subscription, membership,
plan, quota, orders}` were already confirmed 404 there.

---

## Antigravity — nothing found, and **not live re-verified this round**

### What OpenUsage renders today

Session, Weekly, Claude, Claude Weekly, Usage Trend + spend tiles (local,
estimated).

### The blocker, stated plainly

Antigravity's credential lives in the macOS keychain (service `gemini`, account
`antigravity`). OpenUsage's own cache at
`~/Library/Application Support/OpenUsage/antigravity/auth.json` had **expired
7.6 hours before this survey ran**, the Antigravity language server was not
running, and `agy` has no quota/usage subcommand. The only ways forward were
(a) reading the keychain item, which would raise an authorization dialog on the
owner's screen mid-session, or (b) refreshing the Google token — forbidden.
Neither was done, so **Antigravity's findings below are static analysis plus
the live verification from `subscription-expiry.md` (2026-08-27, same
machine)**, not fresh calls.

### Static analysis

`strings` over `agy` lists ~60 `v1internal:*` methods. Every read-shaped one is
already accounted for:

- `retrieveUserQuotaSummary` — the authoritative source, already mapped.
  Its buckets carry `bucketId`, `remainingFraction`, `resetTime` plus
  `displayName` and `window`, and `AntigravityUsageMapper` drops the last two
  (cosmetic). It also **hard-matches four bucket ids** (`gemini-5h`,
  `gemini-weekly`, `3p-5h`, `3p-weekly`) and logs-and-skips anything else — a
  deliberate choice, but it means a new bucket (e.g. an image quota) would be
  silently invisible until someone adds the id.
- `retrieveUserQuota` / `fetchAvailableModels` — the legacy per-model fallback,
  already mapped.
- `loadCodeAssist` — tier eligibility only (verified previously).
- `fetchUserInfo` — `{userSettings:{telemetryEnabled}, regionCode}`.
- `getCodeAssistGlobalUserSetting` — 404 on this base URL.
- `fetchAdminControls`, `listExperiments`, `listModelConfigs`, `listAgents`,
  `listCloudAICompanionProjects` — configuration and enterprise plumbing, no
  usage numbers.
- The only licence-flavoured symbols (`LicenseRequiredInfo`,
  `licenseLengthMonths`) belong to the inherited Codeium/Windsurf
  enterprise-licence proto, not the consumer subscription.

There is **no billing or history method in the Cloud Code surface at all**, and
structurally there shouldn't be: Antigravity's paid tier rides on a Google
account entitlement whose billing lives in Google One / Play.

**Rate-limit warning carried forward:** `:retrieveUserQuota*` returned
`429 RESOURCE_EXHAUSTED` on the previous survey's first attempt. This surface
must not gain speculative calls.

---

## Checked and found nothing — don't redo these

So the next person doesn't repeat the work:

- **Claude account-wide usage history** — the complete `/api/oauth/*` route
  list from `claude.exe` has no history endpoint. `cri` 404s. The web
  dashboard's history is behind cookie-authenticated `/api/organizations/*`,
  which `docs/privacy.md` forbids.
- **Claude `contracts/*`** — `contracts/prepaid/credits` and
  `contracts/auto_reload_settings` are 405 on GET.
- **Codex billing dates from the API** — settled in `subscription-expiry.md`;
  the `id_token` claim is the only source. `/backend-api/{me, accounts/check,
  subscriptions}` are behind a Cloudflare managed challenge.
- **Codex `wham/settings/user` and `wham/tasks/list`** — CLI preferences and an
  empty cloud-task list. No numbers.
- **Grok subscription/renewal date** — settled; `billingPeriodEnd` is a weekly
  usage window, not a billing anniversary.
- **Grok `/v1/billing` history** — present but all zeros for a unified-billing
  subscriber; may be permanently zero for this account class.
- **Grok extra endpoints** — the CLI's whole remote surface is
  `/v1/{settings,billing,models,chat/completions}`. There is nothing else.
- **Cursor team RPCs** — `GetTeamSpend`, `GetOrgDailySpendByCategory`,
  `GetTeamAnalytics`, `GetMcpServerUsageSummary`, `GetOrganizationMembers`,
  `ListInvoices` etc. all require a team id; unusable from a personal account.
  Also `docs/research/cursor-enterprise-usage.md`.
- **Cursor `GetCreditGrantsBalance` / `GetTokenUsage` / `GetDailySpendByCategory`
  with an empty request** — all `{}`. They need parameters.
- **Kimi subscription/plan endpoints** — `/coding/v1/{subscription,
  subscriptions, membership, memberships, plan, quota, orders}` are 404
  (`docs/research/kimi-code-usage-api.md`).
- **Antigravity anything billing-shaped** — no such method exists in
  `cloudcode-pa`.

---

## Recommendations, ordered by (user value ÷ cost)

Ordering assumption: "value" = how often a user would look at it and change
behaviour; "cost" = LOC + extra requests + new failure modes. Everything in
tiers 1–2 costs **zero extra network calls**.

### Tier 1 — free, small, clearly useful

**1. Grok: per-product weekly split.** *Value: high — the single Weekly bar
currently can't say what consumed it.*
Sketch: extend `GrokCreditsConfig` with `productUsage: [(product, percent)]`,
parse it in `GrokCreditsConfigDecoder.decode` (drop unknown/zero entries; a
missing `usagePercent` is a genuine 0 under proto-JSON), and add a
`.values`-style row in `GrokUsageMapper` plus a `grok.products` descriptor.
**~80–110 LOC** across decoder + mapper + `GrokProvider`, plus one fixture test
using the body above. Risk: the product set is undocumented and will grow —
render whatever comes back rather than hardcoding four names.

**2. Claude: mark the binding limit.** *Value: high — four equal bars today,
one of which is the one that will actually stop you.*
Sketch: in `ClaudeUsageMapper`, read `limits[]` once (instead of hunting for
Fable by name), carry `is_active` and `severity` per window, and surface
"active" as a subtitle or colour on the matching `.progress` row. Also
generalizes Fable → every `weekly_scoped` entry for free.
**~60–90 LOC** in the mapper; the existing fixture tests need updating and one
new fixture with an active scoped limit. Risk: `is_active` semantics are
undocumented — on this sample exactly one limit is active, but don't assume
"exactly one" in code.

**3. Cursor: payment-failure warning.** *Value: high when it fires, zero
otherwise — but silent billing failure is the worst kind.*
Sketch: `CursorProvider` already decodes `auth/stripe` for `customerBalance`;
add a `warning` when `lastPaymentFailed == true`, `paymentRecoveryAction` is
non-null, or `subscriptionStatus != "active"`, routed through
`ProviderSnapshot.warning` (the mechanism Claude's rate-limit notice uses).
**~30–40 LOC** + one mapper test. Risk: `subscriptionStatus`'s full value set
is unknown — warn only on the two explicit booleans and treat an unknown status
as fine, rather than nagging on a status we've never seen.

**4. Z.ai: raw credit counts on Session and Weekly.** *Value: medium-high —
"1,168 of 28,000" beats "4%".*
Sketch: `ZAIUsageMapper.mapQuota` currently builds `.progress(used:
percentage, limit: 100, format: .percent)`. Read `currentValue` / `usage`
instead and keep `percentage` as the fallback when either is missing.
**~40–60 LOC** + fixture updates. Risk: unit semantics — `usage` is the
allowance and `currentValue` the consumed amount, which is the opposite of the
naming instinct; the doc'd sample (`1168 / 28000`, `percentage: 4`) is the
check.

**5. Codex: the `gpt-reserve` meter.** *Value: medium — a real second weekly
window nobody can see today.*
Sketch: turn `CodexUsageMapper.sparkLines`'s single `first(where: isSparkEntry)`
into a loop over `additional_rate_limits`, labelling each pair from
`limit_name`. Needs a naming rule (`"GPT-5.3-Codex-Spark"` → "Spark",
`"gpt-reserve"` → "GPT Reserve") and new descriptors.
**~50–80 LOC**; new descriptors mean new metric IDs, so this touches
`DefaultLayout` and `LocalLimitsAPITests`. Risk: an unbounded number of
additional limits could mean an unbounded number of rows — cap it, or only
promote known names.

**6. Z.ai: named per-tool MCP breakdown.** *Value: medium.*
Sketch: `ZAIActivityMapper.parseToolUsage` reads `toolSummaryList[]`
(`toolNameI18n` + `totalUsageCount`) instead of the three hardcoded totals.
**~40 LOC** + fixture. Risk: `toolName` is Chinese and `toolNameI18n` English —
always read the latter.

### Tier 2 — the big one, and it isn't free

**7. Codex: account-wide token history from `wham/profiles/me`.** *Value:
highest in the survey — it's the only Z.ai-grade new data class anywhere here.*
Sketch: a `fetchProfileStats` method on `CodexUsageClient` (same bearer, same
`ChatGPT-Account-Id`), a small parser turning `daily_usage_buckets` into a
`DailyUsageSeries`, and a **new** `.accountWide`, `estimatedCost: false`
history resource on the Codex descriptor — it must not merge with or overwrite
the existing `.machineLocal` scanned trend, because the two measure different
things (one machine + priced estimate vs all machines + tokens only). Plus
optional `.values` rows for lifetime tokens / streak / threads.
**~200–260 LOC** across client, a new mapper file, `CodexProvider`,
`DefaultLayout`, `LocalLimitsAPITests`, `docs/providers/codex.md`, and a
9 KB JSON fixture.
Risks, all real: **+1 request per refresh** on a provider that already makes
two; the data is a **daily batch** (`stats_as_of` yesterday) so it will always
disagree with the live local trend by a day and must be labelled as such;
buckets are **sparse** (missing day ≠ zero); tokens only, so it can never feed
the spend tiles; and the payload carries username/avatar that must be dropped
on the floor at the parse boundary. Given the refresh cost and the staleness,
consider fetching it on a slower cadence than the meters.

### Tier 3 — worth doing only with a reason

**8. Claude: prepaid credit balance + monthly purchase cap.** Two new
endpoints, org-UUID plumbing, **+1–2 requests** on a rate-limit-sensitive
provider, and **zero visible value for anyone who has never bought credits**
(both read 0 here, and `can_purchase_credits: false` on this plan).
**~120–160 LOC**. Ship it only if a user asks, and only as an opt-in row that
hides itself when the balance is null/zero and `credits_ever_enabled` is false.

**9. Cursor: replace the CSV with `GetAggregatedUsageEvents` /
`GetDailySpendByCategory`.** Same numbers for the user, but authoritative cost
from Cursor instead of imputed, compact JSON instead of a CSV, and one less
parser exposed to column drift. **~150–200 LOC** to swap the source plus
fixtures, and it deletes `CursorCSVParser`'s risk surface. Do it opportunistically
— e.g. the next time the CSV export breaks — not as a standalone feature.

**10. Codex `thread_usage/query` (OpenAI's own per-thread USD).** Would let the
Codex spend tiles stop imputing prices entirely. **Requires a POST**, so it was
not verified; verify it first (one approved call), then estimate.

**11. Kimi: `parallel.limit` badge; Grok `onDemandUsed`/`prepaidBalance`;
Cursor `bonus` split; Claude `spend_limit_reached` reason.** Each is 10–30 LOC
of the same "read a field we already have" pattern. Bundle them into whichever
tier-1 change touches the same mapper rather than shipping them alone.

---

## Metric-placement defaults — **owner decision, not settled here**

AGENTS.md requires the four defaults be confirmed rather than chosen. These are
**proposals awaiting sign-off**, for every row proposed above:

| Proposed row | Enabled? | Always Visible / On Demand | Pinned? | Order |
|---|---|---|---|---|
| `grok.products` (per-product split) | **on** | **On Demand** — a breakdown belongs under the caret, not competing with the Weekly bar | **no** | right after `grok.weekly` |
| Claude "active limit" marker | n/a — a **modifier on existing rows**, not a new row | n/a | n/a | n/a |
| Cursor payment warning | n/a — a **provider header warning**, not a row | n/a | n/a | n/a |
| Z.ai credit counts | n/a — **changes the existing** `zai.session` / `zai.weekly` values | n/a | unchanged | unchanged |
| `codex.gptReserve` / `codex.gptReserveWeekly` | **on** | **On Demand** — mirrors how `codex.spark` / `codex.sparkWeekly` are seeded | **no** | immediately after the Spark pair |
| Z.ai per-tool MCP rows | n/a — **changes the existing** `zai.mcpTools` row | n/a | unchanged | unchanged |
| `codex.accountTrend` (account-wide token history) | **on** | **Always Visible**? — genuinely open. It duplicates a visible trend, which argues On Demand; it's also better data, which argues the reverse | **no** — a chart is a poor menu-bar tile, suggest `pinnable: false` like `usageTrend` | after the existing `codex.trend` |
| `codex.lifetimeTokens` / `codex.streak` | **off** by default | **On Demand** | **no** | last, after the spend tiles |
| `claude.credits` (prepaid balance) | **off** by default — it reads 0 for almost everyone | **On Demand** | **no** | after `claude.extra` |
| `claude.creditPurchases` (monthly bundle cap) | **off** | **On Demand** | **no** | after `claude.credits` |
| `kimi.parallel` | **off** | **On Demand** | **no** | last |

Reminder from AGENTS.md: a provider always keeps at least one Always Visible
row, so none of the above may push a provider fully On Demand. Codex, Grok,
Claude and Z.ai all keep their existing meters above the fold, so the caret
still appears in every case.

---

## Privacy notes

- **New network destinations.** Only two proposals add a host-path that
  `docs/privacy.md` doesn't already list: Codex `wham/profiles/me` (same host,
  `chatgpt.com`, already listed) and Claude `…/prepaid/{credits,bundles}` (same
  host, `api.anthropic.com`, already listed). No new *host* in either case, but
  the "Other network requests" section should still name the new paths.
- **Identity in the payloads.** `wham/profiles/me` returns username, display
  name and an avatar URL; `/coding/v1/me` returns a phone number; Cursor's
  `auth/stripe` returns a Stripe customer id and card metadata; Claude's
  `claude_cli/roles` and `bootstrap` return org UUIDs and the account e-mail.
  Every one of these must be dropped at the parse boundary — read the specific
  field and never log, persist or transmit the surrounding object.
- **PostHog.** Everything proposed here is a usage value or a billing figure.
  `docs/privacy.md` already promises no actual usage values leave the machine;
  token counts, credit balances and spend figures belong in exactly that
  bucket.
- **iCloud Sync / local HTTP API.** The Codex account-wide history is
  `.accountWide`, which by the same rule Cursor's CSV history follows must
  **not** be merged across devices or written to the iCloud sync file. Confirm
  with the owner before exporting any of the new values through
  `docs/local-http-api.md`.
- **No token was refreshed** during this survey, and claude-swap's keychain
  entries were not read at all — the boundary `FORK.md` and `docs/privacy.md`
  commit to is intact.

---

## What could not be verified, and why

1. **Antigravity was not live re-probed.** Expired cached token, language
   server not running, and the only alternatives were a keychain authorization
   dialog on the owner's screen or a forbidden token refresh. Findings there
   rest on static analysis of `agy` plus the live verification in
   `subscription-expiry.md` (2026-08-27, same machine).
2. **Codex `thread_usage/query` was not called** — POST-only, and this survey
   was GET-only by rule. Its response *types* are read from the binary and look
   very promising (per-thread USD); one approved POST would settle it.
3. **Team / org / enterprise shapes** are unverifiable on this machine. Every
   account here is personal: Cursor `isTeamMember: false`, Grok `teamId: null`,
   Claude `seat_tier: null`, Codex `workspace_rank: null`. Anything about team
   pooling, workspace ranks or org spend is inference from field names.
4. **Populated shapes for empty balances.** Claude `prepaid/credits`
   (`tranches: []`, `next_expires_at: null`), Cursor `GetCreditGrantsBalance`
   (`{}`), Grok `history[]` (all zeros) and Codex `credits` (balance 0) are all
   at zero on this machine — the *field names* are known but the populated
   shapes are not observed.
5. **Claude's `*_dollars` window fields** are null on this Max plan. Whether
   any plan reports usage windows in money is unknown.
6. **Kimi's global region** (`api.kimi.ai`) was not exercised; only CN
   (`api.kimi.com`). The shape is documented as identical.
7. **Kimi's session `used` field** — this account's 5-hour window carried only
   `remaining`, so whether `used` ever appears (and therefore whether the
   Session meter can ever read non-zero) is unconfirmed.
8. **Z.ai endpoint discovery** was limited to the four known paths: there is no
   Z.ai CLI to reverse-engineer, and no blind path-guessing was done.
