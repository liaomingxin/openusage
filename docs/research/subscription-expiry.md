# Subscription Expiry / Renewal Dates: What Each Provider Exposes

Research + live verification of whether OpenUsage can read a "subscription
renews / expires on `<date>`" value for each provider **using only the
credentials its auth store already loads from this Mac**. Done 2026-08-27.
No implementation — this is the availability survey behind a possible
"Renews" card row.

Method: read every provider's auth store / usage client / mapper, then make
read-only live calls with the real local credentials (same files, same header
shapes the app uses), plus static reverse engineering of the installed
`codex`, `claude`, `grok` and `agy` binaries for endpoints their own account
screens use. Every account identifier, e-mail, org UUID and customer ID below
is redacted; no token, cookie or API key was printed, saved or is reproduced
here. All seven providers had usable credentials on this machine, so every
verdict is live-verified unless stated otherwise.

## TL;DR

Three providers hand us a real renewal date, and **all three are already in
data OpenUsage fetches or reads today** — no new endpoint, no new credential,
no extra request:

| Provider | Renewal date? | Where it already is |
|---|---|---|
| Cursor | yes | `usage-summary.billingCycleEnd` (already fetched, already used as `resetsAt`) |
| Z.ai | yes | `subscription/list[0].nextRenewTime` (already fetched, only `productName` is read) |
| Codex | yes, with staleness | `id_token` claim in `~/.codex/auth.json` (already parsed for the account id) |

The other four expose plan tier and usage-window resets but no billing date.

---

## Cursor — **available** (live-verified)

Three separate endpoints agree on the same period end, and OpenUsage already
calls two of them.

### 1. `usage-summary` — the one already in hand

```
GET https://cursor.com/api/usage-summary
Cookie: WorkosCursorSessionToken=<userId>%3A%3A<accessToken>
```

```json
{
  "billingCycleStart": "2026-08-16T13:11:01.000Z",
  "billingCycleEnd":   "2026-09-16T13:11:01.000Z",
  "membershipType": "ultra",
  "limitType": "user",
  "isUnlimited": false,
  "individualUsage": { "plan": { "used": 5140, "limit": 40000, … } }
}
```

`CursorUsageSummaryMapper.billingCycle(summary:requestUsage:)` already parses
both fields — it uses `end` as the meters' `resetsAt` and `end - start` as the
period duration, then throws the date away as a standalone value. A "Renews"
row costs **zero extra network calls**.

### 2. `GetPlanInfo` — same date, plus price and plan owner

```
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo
Authorization: Bearer <access token>
Connect-Protocol-Version: 1
Content-Type: application/json
{}
```

```json
{ "planInfo": {
    "planName": "Ultra",
    "includedAmountCents": 40000,
    "price": "$200/mo",
    "billingCycleEnd": "1789564261000",
    "planOwner": "PLAN_OWNER_STRIPE" } }
```

`billingCycleEnd` is epoch **milliseconds as a string** (`1789564261000` =
`2026-09-16T13:11:01Z`), identical to the ISO value above. `price` carries the
billing interval in plain text (`"$200/mo"`), and `planOwner` distinguishes a
Stripe-billed individual from a team/enterprise seat. OpenUsage already calls
this endpoint (`CursorUsageClient.fetchPlan`).

### 3. `auth/stripe` — the renewal *semantics*

```
GET https://cursor.com/api/auth/stripe
Cookie: WorkosCursorSessionToken=<userId>%3A%3A<accessToken>
```

```json
{
  "membershipType": "ultra",
  "paymentId": "cus_…",
  "subscriptionStatus": "active",
  "trialEligible": false,
  "trialLengthDays": 7,
  "trialWasCancelled": false,
  "isTeamMember": false,
  "teamMembershipType": null,
  "individualMembershipType": "ultra",
  "lastPaymentFailed": false,
  "pendingCancellationDate": null,
  "paymentRecoveryAction": null,
  "isYearlyPlan": false,
  "customerBalance": 0
}
```

This is the endpoint that tells us whether `billingCycleEnd` means *renews* or
*expires*: `pendingCancellationDate != null` (or `subscriptionStatus` leaving
`active`) turns the row into "Ends". `isYearlyPlan` gives the interval,
`isTeamMember`/`teamMembershipType` the team case, `lastPaymentFailed` and
`paymentRecoveryAction` the dunning case. OpenUsage already calls this
endpoint too (`fetchStripeBalance`), reading only `customerBalance`.

**Semantics.** `billingCycleEnd` is the current period end = next charge date
while the subscription is active. **Caveats:** all three calls need the
`WorkosCursorSessionToken` cookie form or the Connect bearer, i.e. the
existing refresh path; team seats were not verifiable on this machine (this
account is `isTeamMember: false`), and a yearly plan's cycle end was likewise
not observable here — both are inferred from the field names. Trial state is
only *eligibility* (`trialEligible`/`trialLengthDays`), not a trial end date.

---

## Z.ai — **available** (live-verified)

The endpoint OpenUsage already calls for the plan name carries the entire
billing agreement.

```
GET https://api.z.ai/api/biz/subscription/list
Authorization: Bearer <user API key>
Accept: application/json
```

```json
{ "code": 200, "success": true, "data": [ {
    "id": "…", "customerId": "…", "agreementNo": "…", "orderNo": "…",
    "productName": "GLM Coding Max",
    "description": "GLM Coding Max",
    "status": "VALID",
    "purchaseTime": "2026-08-23 15:40:12",
    "valid": "2026-11-23 10:00:00-2027-02-23 10:00:00",
    "currentPeriod": 2,
    "currentRenewTime": "2026-08-23",
    "nextRenewTime": "2026-11-23",
    "billingCycle": "quarterly",
    "autoRenew": 1,
    "inCurrentPeriod": true,
    "paymentType": "WAIT_PAY",
    "refundable": false,
    "banStatus": 0, "banExpireTime": null,
    "renewPrice": 2587.2, "actualPrice": 2587.2,
    "version": "V3" } ] }
```

`ZAIUsageMapper.planName(from:)` reads `productName` from exactly this body
and drops everything else, so a "Renews" row is **free**.

**The field to use is `nextRenewTime`** (`2026-11-23`): current period runs
`currentRenewTime → nextRenewTime`, and `billingCycle` (`quarterly` here;
expect `monthly`/`yearly` too) plus `autoRenew` (`1`/`0`) give interval and
auto-renew state. `status: "VALID"` is the active flag; `banStatus` /
`banExpireTime` is a suspension, not a subscription end.

**Caveats.**
- `valid` looks like it describes the *upcoming* period, not the current one
  (`2026-11-23 → 2027-02-23` while the current period is `08-23 → 11-23`),
  most likely because `paymentType` is `WAIT_PAY` for the pending renewal
  invoice. Do not use `valid` for "renews on"; use `nextRenewTime`.
- No timezone marker on any of these strings. Prices are plainly CNY
  (`renewPrice: 2587.2`), so Beijing time (UTC+8) is the likely basis — this
  needs one empirical check before shipping, or the row should render
  date-only (`Nov 23`) and dodge the question.
- `data` is an array. Plan changes and stacked add-ons could produce more than
  one entry; the mapper already takes `data[0]` for the plan name, so a
  "renews" reader should at least prefer the entry with `inCurrentPeriod:
  true` / `status: "VALID"`.
- Undocumented internal API behind the z.ai subscription UI — same stability
  guarantee (none, but stable in practice) the app already accepts here.
- The quota endpoint (`/api/monitor/usage/quota/limit`) carries only
  `level: "max"` and per-window `nextResetTime`s — usage windows, not billing.

---

## Codex — **available locally, with a staleness caveat** (live-verified)

No ChatGPT endpoint reachable with the CLI token returns billing dates — but
the **`id_token` already sitting in `~/.codex/auth.json` does**.

```
~/.codex/auth.json → tokens.id_token → JWT payload
  → claim "https://api.openai.com/auth"
```

```json
{
  "chatgpt_plan_type": "pro",
  "chatgpt_subscription_active_start": "2026-07-26T17:13:33+00:00",
  "chatgpt_subscription_active_until": "2026-08-26T17:14:28+00:00",
  "chatgpt_subscription_last_checked": "2026-08-08T10:38:07.224122+00:00",
  "chatgpt_account_id": "…", "chatgpt_user_id": "…", "poid": "org-…",
  "organizations": [ { "id": "org-…", "role": "owner", "is_default": true } ]
}
```

`CodexAuthStore` already decodes this exact JWT (it reads the ChatGPT account
claim out of it via `ProviderParse.jwtPayload`), so this is a **pure local
parse: no network call at all**. `active_start → active_until` is the current
paid period (a clean month here), i.e. the renewal date for an auto-renewing
plan.

**The caveat is freshness.** Measured on this machine:

| Token | Lifetime |
|---|---|
| `access_token` | 10 days (`iat` → `exp`) |
| `id_token` | 1 hour, but persisted next to it |

`CodexAuthStore.accessTokenRefreshWindow` refreshes 5 minutes before the
*access* token's `exp`, so the stored `id_token` — and with it
`active_until` — is only rewritten roughly every 10 days (sooner whenever the
user's own `codex` CLI refreshes the same file). The live sample shows the
failure mode exactly: `active_until` read `2026-08-26T17:14:28Z`, which had
already passed at read time. `chatgpt_subscription_last_checked`
(`2026-08-08`) shows OpenAI's own snapshot lags too.

Implementation must therefore either (a) treat a past `active_until` as "the
period rolled over" and roll it forward by the observed period length, or (b)
suppress the row until the next refresh, or (c) force a token refresh when the
value goes stale — the app already persists rotated Codex credentials, so (c)
is possible but spends a refresh purely for a display value. (a) is the
cheapest honest option.

Also: this claim exists only for OAuth logins. An `OPENAI_API_KEY` Codex
account has no `id_token` and gets no row.

### What the ChatGPT endpoints *don't* give (all live-verified)

| Call | Result |
|---|---|
| `GET /backend-api/wham/usage` | 200 — `plan_type: "pro"`, rate-limit windows, credits, reset credits. **No billing dates.** |
| `GET /backend-api/wham/profiles/me` | 200 — username, lifetime token stats, daily buckets. No billing. |
| `GET /backend-api/wham/settings/user` | 200 — CLI preferences only. |
| `GET /backend-api/wham/config/bundle` | 400 `No active workspace`. |
| `GET /backend-api/me` | **403, `cf-mitigated: challenge`** |
| `GET /backend-api/accounts/check/v4-2023-04-27` | **403, `cf-mitigated: challenge`** |
| `GET /backend-api/subscriptions` | **403, `cf-mitigated: challenge`** |
| `GET https://auth.openai.com/oauth/userinfo` | 200 — `sub`, `name`, `email`, `email_verified` only. |

The historical `subscription_expires_at` / `has_paid_subscription` fields on
`/backend-api/me` and `/accounts/check` are **unreachable**: those browser
routes sit behind a Cloudflare managed challenge that a non-browser client
cannot pass (retried with full browser headers — same 403). Only the `wham/*`
namespace the Codex CLI uses is exempt. Endpoint inventory came from `strings`
over the `codex` Rust binary (`@openai/codex-darwin-arm64`), which lists the
complete `/wham/*` and `/api/codex/*` path sets; nothing billing-shaped exists
in either beyond the reset-credits routes OpenUsage already uses.

---

## Claude — **partial: status yes, renewal date no** (live-verified)

```
GET https://api.anthropic.com/api/oauth/profile
Authorization: Bearer <access token>
anthropic-beta: oauth-2025-04-20
```

```json
{
  "account": { "uuid": "…", "email": "user@…",
               "has_claude_max": true, "has_claude_pro": false,
               "created_at": "2024-03-06T02:31:06.289557Z" },
  "organization": {
    "uuid": "…", "organization_type": "clau…",
    "billing_type": "stripe_subscription",
    "rate_limit_tier": "default_claude_max_20x",
    "seat_tier": null,
    "has_extra_usage_enabled": true,
    "subscription_status": "active",
    "subscription_created_at": "2026-01-20T18:40:15.665168Z",
    "claude_code_trial_ends_at": null,
    "claude_code_trial_duration_days": null,
    "payment_auth_hosted_invoice_url": null }
}
```

Available: plan tier (`has_claude_max`/`has_claude_pro`, `rate_limit_tier`),
`subscription_status`, `billing_type`, `seat_tier` (team/enterprise),
`claude_code_trial_ends_at` (a real trial end date when a Claude Code trial is
running — `null` on this account) and `subscription_created_at`.
**Not available: any next-billing / period-end / cancel-at-period-end field.**

The app already calls this endpoint (`ClaudeUsageClient.verifyAccount` hits
`/api/oauth/profile`), and the `claude` CLI caches the identical field set into
`~/.claude.json` under `oauthAccount` — same fields, same gap.

Endpoints probed for a billing date (all with the same OAuth token):

| Call | Result |
|---|---|
| `GET /api/oauth/usage` | 200 — windows, `resets_at`, extra-usage credits. No billing dates. |
| `GET /api/oauth/account/settings` | 200 — onboarding flags / dismissed banners only. |
| `GET /api/oauth/organizations/<org>/payment_method` | 200 — `{brand, country, last4, type}`. **No dates.** |
| `GET /api/oauth/organizations/<org>` | 404 |
| `GET /api/oauth/organizations/<org>/subscription` | 404 |
| `GET /api/oauth/organizations/<org>/billing` | 404 |
| `GET /api/oauth/organizations/<org>/billing/tax_rate` | 405 (not GET) |
| `GET /api/oauth/organizations/<org>/overage_spend_limit` | 405 (not GET) |
| `GET /api/oauth/validate` | 405 (not GET) |

The endpoint list came from `strings` over `claude.exe` (the Claude Code
bundle): the complete `/api/oauth/*` surface is `profile`, `usage`, `validate`,
`account/settings`, `account/grove_notice_viewed`, `claude_cli/*`, `cri`,
`file_upload`, `files/`, and `organizations/:orgUUID/{admin_requests,
billing/tax_rate, claude_code/pro_trial, contracts/*, mcp/connectors/*,
overage_credit_grant, overage_spend_limit, payment_method, plugin_ratings}`.
None is a subscription/billing-period read. (`pro_trial`,
`overage_credit_grant` and `create_api_key` are mutating and were deliberately
not called.)

The claude.ai web app's own billing screen uses cookie-authenticated
`/api/organizations/...` routes, not the OAuth token — and `docs/privacy.md`
commits that OpenUsage never uses Claude Desktop's cookies, so that path is
out of bounds by policy, not just by scope.

**Derivable but not recommended:** `subscription_created_at` gives an
anniversary day-of-month (the 20th here), so a monthly renewal *could* be
extrapolated. Plan upgrades, proration, pauses and yearly terms all break it,
and it would be a guess rendered as a fact. Don't.

Note: `~/.claude/.credentials.json` also has `refreshTokenExpiresAt`. That is a
**credential** expiry, not a subscription expiry — do not surface it as one.

---

## Grok — **not exposed** (live-verified)

The billing endpoints return *usage* periods, not subscription periods.

```
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <access token>
X-XAI-Token-Auth: xai-grok-cli
```

```json
{ "config": {
    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                       "start": "2026-08-23T15:36:17.876652+00:00",
                       "end":   "2026-08-30T15:36:17.876652+00:00" },
    "creditUsagePercent": 5.0,
    "billingPeriodStart": "2026-08-23T15:36:17.876652+00:00",
    "billingPeriodEnd":   "2026-08-30T15:36:17.876652+00:00",
    "onDemandCap": {"val": 0}, "prepaidBalance": {"val": 0},
    "isUnifiedBillingUser": true, "topUpMethod": "TOP_UP…" } }
```

Here `billingPeriodStart/End` just mirror the **weekly credit window**
(`USAGE_PERIOD_TYPE_WEEKLY`) — which `GrokCreditsConfigDecoder` already reads
as the weekly meter's `resetsAt`. The same endpoint *without* `format=credits`
returns a plain calendar-month window (`2026-08-01T00:00:00Z →
2026-09-01T00:00:00Z`) with `monthlyLimit: 0` and a 3-month `history[]` — a
calendar rollup of API-credit spend, not a subscription anniversary.

Other probes:

| Call | Result |
|---|---|
| `GET /v1/settings` | 200 — `subscription_tier_display: "SuperGrok Heavy"` (tier only, already used as the plan name), `subscription_watch_interval_secs`, feature flags. No dates. |
| `GET /v1/user` | 200 — ids, e-mail, team/org fields (all null here), `hasGrokCodeAccess: true`. No dates. |
| `GET /v1/billing/usage`, `/v1/subscription`, `/v1/me` | 404 |
| `GET https://{accounts,auth}.x.ai/auth/check_subscription` | **403 Cloudflare** |
| `GET https://api.x.ai/auth/check_subscription` | 404 |

`strings` over the `grok` binary (1.0.5) shows the CLI's only billing calls are
`/v1/billing` and `/v1/billing?format=credits`, plus a paywall probe at
`…x.ai/auth/check_subscription` (`crates/.../agent/subscription_check.rs`,
feeding `paywall_check_subscription_detected`) — a boolean/tier gate, and in
any case behind Cloudflare from a non-browser client. `billing/retry` exists
and is mutating; not called.

**Verdict: tier yes, renewal date no.** Do not repurpose `billingPeriodEnd`
into a "Renews" row — on this account it is a weekly usage window and would
read as a weekly subscription renewal.

---

## Kimi Code — **not exposed** (live-verified)

```
GET https://api.kimi.com/coding/v1/usages
Authorization: Bearer <access token>
```

```json
{ "user": { "userId": "…", "region": "REGION_CN",
            "membership": { "level": "LEVEL_ADVANCED" }, "businessId": "" },
  "usage": { "limit": "100", "used": "100",
             "resetTime": "2026-08-28T03:18:21.328791Z" },
  "limits": [ { "window": {"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                "detail": {"limit":"100","remaining":"100",
                           "resetTime":"2026-08-26T23:18:21.328791Z"} } ],
  "parallel": {"limit":"30"}, "totalQuota": {},
  "authentication": {"method":"METHOD_ACCESS_TOKEN","scope":"FEATURE_CODING"},
  "subType": "TYPE_PURCHASE", "domain": "DOMAIN_NEXUS" }
```

`resetTime` is the quota reset (weekly / 5-hour), already mapped. `subType:
TYPE_PURCHASE` says "this is a subscription" and `membership.level` gives the
tier — neither carries a date. `totalQuota` is an **empty object** on this
account; if it ever carries a period on other plans it would be worth
re-checking, but there is nothing to read today.

```
GET https://api.kimi.com/coding/v1/me
→ { "user_id": "…", "nickname": "…", "status": "USER_STATUS_NORMAL",
    "region": "REGION_CN", "user_level": 27, "user_level_name": "…",
    "created_time": "2024-03-12T10:05:54.328608Z",
    "last_login_time": "2026-08-22T15:16:20.870686Z" }
```

Account dates, not subscription dates. `/coding/v1/{subscription,
subscriptions, membership, memberships, plan, quota, orders}` all return
`404 resource_not_found_error`. `docs/research/kimi-code-usage-api.md` already
documents `usages` and `me` as the entire Kimi Code surface, and nothing in the
`kimi` binary contradicts that.

**Region note:** verified against the CN region (`~/.kimi-code/region` = `cn`,
host `api.kimi.com`). The global host is `api.kimi.ai`; the payload shape is
the same, so the *absence* of a billing field is expected to hold, but that is
inferred rather than verified.

**Token note:** the Kimi access token lives 15 minutes and its refresh
**rotates the refresh token**, so this verification deliberately used the
already-valid stored access token rather than refreshing — refreshing without
writing the new pair back would have broken the user's `kimi` login.

---

## Antigravity — **not exposed** (live-verified)

```
POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
Authorization: Bearer <Google access token>
User-Agent: agy
{}
```

```json
{ "allowedTiers": [ { "id": "standard-tier", "name": "Gemini Code Assist",
      "description": "Unlimited coding assistant with the most powerful Gemini models",
      "isDefault": true, "usesGcpTos": true, "userDefinedCloudaicompanionProject": true } ],
  "ineligibleTiers": [ { "tierId": "free-tier",
      "tierName": "Gemini Code Assist for individuals",
      "reasonCode": "UNSUPPORTED_CLIENT" } ] }
```

Tier eligibility only — no `currentTier`, no license window, no expiry.

```
POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
User-Agent: antigravity
{}
→ groups[].buckets[] = { bucketId, displayName, window: "weekly"|"5h",
                         resetTime: "2026-09-01T06:25:41Z", remainingFraction }
```

`resetTime` is a quota window reset, already mapped by
`AntigravityUsageMapper`. `POST :fetchUserInfo` returns
`{"userSettings":{"telemetryEnabled":true},"regionCode":"US"}`.
`:getCodeAssistGlobalUserSetting` 404s on this base URL.

`strings` over `agy` lists ~55 `v1internal:*` methods; the only
licence-flavoured symbols (`LicenseRequiredInfo`, `licenseLengthMonths`,
`licensesFetchedMsg`) belong to the `exa.language_server_pb` proto — the
Codeium/Windsurf enterprise-licence path, not the consumer subscription. There
is no billing method in the Cloud Code surface at all.

Structurally this is expected: Antigravity's paid tier rides on a Google
account entitlement (Google AI Pro/Ultra), whose billing lives in Google One /
Play, not in `cloudcode-pa`. **Not obtainable with the Antigravity credential.**

**Rate-limit note:** `:retrieveUserQuota` and `:retrieveUserQuotaSummary`
returned `429 RESOURCE_EXHAUSTED` on the first attempt with `User-Agent: agy`
and succeeded with `User-Agent: antigravity`. Whatever the cause, this surface
is rate-limit sensitive — an implementation must not add speculative calls
here.

---

## Summary table

| Provider | Verdict | Source | Extra request? | Confidence |
|---|---|---|---|---|
| **Cursor** | **available** | `GET cursor.com/api/usage-summary` → `billingCycleEnd` (also `GetPlanInfo.billingCycleEnd`; `auth/stripe` for renew-vs-cancel) | none — already fetched | live-verified |
| **Z.ai** | **available** | `GET api.z.ai/api/biz/subscription/list` → `data[].nextRenewTime` | none — already fetched | live-verified |
| **Codex** | **available (stale ≤10 d)** | `~/.codex/auth.json` → `id_token` claim `chatgpt_subscription_active_until` | none — local file parse | live-verified |
| **Claude** | **partial** — status/tier/trial-end only, no renewal date | `GET api.anthropic.com/api/oauth/profile` → `subscription_status`, `claude_code_trial_ends_at` | none — already called | live-verified |
| **Grok** | **not exposed** — tier only | `GET cli-chat-proxy.grok.com/v1/settings` → `subscription_tier_display`; billing endpoints return usage windows | n/a | live-verified |
| **Kimi Code** | **not exposed** — tier only | `GET api.kimi.com/coding/v1/usages` → `membership.level`, `subType` | n/a | live-verified (CN region; global inferred) |
| **Antigravity** | **not exposed** | `cloudcode-pa` `:loadCodeAssist` / `:retrieveUserQuotaSummary` — tiers and quota windows only | n/a | live-verified |

---

## Implementation recommendation

### Scope: three providers, zero new network calls

Ship the row for **Cursor, Z.ai and Codex** only. Each value already arrives in
a payload OpenUsage fetches (Cursor, Z.ai) or a file it already parses
(Codex), so the feature adds no request, no credential and no new host to
`docs/privacy.md`'s "Other network requests". Skip Claude, Grok, Kimi and
Antigravity — a row that only some providers can fill is better than one
filled with a guess.

| Row | Provider | Value from | Renew-vs-expire signal |
|---|---|---|---|
| `cursor.renews` | Cursor | `usage-summary.billingCycleEnd` (fallback `GetPlanInfo.billingCycleEnd`, epoch-ms string) | `auth/stripe.pendingCancellationDate` non-null or `subscriptionStatus != "active"` → label "Ends" |
| `zai.renews` | Z.ai | `subscription/list[…].nextRenewTime` (prefer the `inCurrentPeriod: true` / `status: "VALID"` entry) | `autoRenew == 0` → "Ends"; `status != "VALID"` → hide the row |
| `codex.renews` | Codex | `id_token` claim `chatgpt_subscription_active_until` | none available — always "Renews"; suppress or roll forward when the date is in the past |

### Row shape

Two options; **recommend the second.**

1. **`.badge(label: "Renews", text: "Sep 16")`** — smallest change, no model
   work. But `.badge` carries a baked string, so the row can't honor the global
   `ResetDisplayMode` toggle ("Countdown" ⟷ "Exact Time") the way every
   bounded row's reset label does, and it re-introduces formatting in the
   mapper that `MetricLine`'s doc comment explicitly steers away from.
2. **A new `MetricLine.date(label:at:colorHex:subtitle:)` case** carrying a raw
   `Date`, formatted at the display edge like `resetsAt`. Costs a
   `MetricLine` case + `Codable` keys + `WidgetData` mapping + a
   `LocalUsageAPI` wire shape, but the row then reads "Renews in 20d" or
   "Renews Sep 16" with the existing toggle, for free, forever.

Rough effort: option 1 ≈ half a day across three mappers plus tests; option 2 ≈
1–1.5 days including the model/`WidgetData`/local-API plumbing and fixtures.
Either way each provider needs a mapper change, a `WidgetDescriptor`, a
`DefaultLayout` entry, fixture-based mapper tests (the three payloads above
make good fixtures) and a `docs/providers/<name>.md` update.

Not pinnable-friendly: a date is wide and changes once a month, so it is a poor
menu-bar tile. Suggest `pinnable: false` on the descriptor, like
`usageTrend(provider:)`.

### Codex staleness handling (the one real design decision)

`chatgpt_subscription_active_until` is a snapshot from the last OAuth refresh
and can be up to ~10 days old (see above; the live sample was already past).
Recommended: render the claim, and when `active_until < now`, roll it forward
by whole `active_until - active_start` periods until it is in the future and
mark the row as approximate (or simply hide it) rather than showing a date that
has already gone by. Do **not** trigger an extra token refresh just to freshen
a display value.

### Privacy notes

- No new network destinations, so `docs/privacy.md`'s "Other network requests"
  section is unchanged.
- The values are billing dates. They are shown locally and, like every other
  metric value, must never reach PostHog — privacy.md already promises "no
  actual usage **values**"; a renewal date belongs in the same bucket.
- The Codex path reads a claim from a credential file the app already opens,
  and only a date leaves that parse — no new credential material is touched,
  copied or cached.
- If the row ships to the local HTTP API (`docs/local-http-api.md`) and iCloud
  Sync, confirm with the owner first: iCloud Sync today carries "normalized
  daily tokens, spend, and model totals" and explicitly not "account limits",
  so a billing date is arguably out of scope for that container.
- Cursor's `auth/stripe` response also contains `paymentId` (`cus_…`) and card
  metadata. Read only `pendingCancellationDate` / `subscriptionStatus` /
  `isYearlyPlan`; never log or persist the rest.

### Metric-placement defaults — **owner decision, not picked here**

AGENTS.md requires the four defaults be confirmed rather than chosen silently.
Proposals, for approval:

| Default | Proposal | Why |
|---|---|---|
| Enabled (`DefaultLayout.metricIDs`) | **on** | It's one line and answers a question users ask; cheap to turn off. |
| Always Visible vs On Demand (`expandedMetricIDs`) | **On Demand** (behind the caret) | A once-a-month date shouldn't compete with live meters above the fold. Each of the three providers keeps its existing Always Visible meters, so the caret still appears. |
| Pinned (`pinnedMetricIDs`) | **not pinned** | Too wide and too static for the menu bar; suggest `pinnable: false` outright. |
| Order (`widgetDescriptors` declaration order) | **last** within each provider, after the spend/trend rows | It's account metadata, not usage. |

### Open questions for the owner

1. Ship all three providers together, or Cursor + Z.ai first and Codex once the
   staleness behavior is agreed?
2. Option 1 (`.badge`, half a day, no `ResetDisplayMode` support) or option 2
   (new `.date` line, ~1.5 days, toggles like every other date in the app)?
3. One label or two — always "Renews", or "Renews"/"Ends" switching on
   `pendingCancellationDate` (Cursor) and `autoRenew` (Z.ai)?
4. Should the row surface plan interval too (Cursor `isYearlyPlan` / `price`,
   Z.ai `billingCycle`) as a subtitle, or stay date-only?
5. Claude has no renewal date but does have `claude_code_trial_ends_at`. Worth
   a trial-only row on Claude, or leave Claude out entirely?
6. Should this value be excluded from the local HTTP API and iCloud Sync (see
   privacy notes)?
