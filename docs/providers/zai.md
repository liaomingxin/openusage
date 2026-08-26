# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) GLM Coding Plan usage quotas for coding subscriptions.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window token usage (percentage) |
| Weekly | 7-day rolling window token usage (percentage) |
| Web Searches | Monthly web-search / web-reader / Zread calls (used / limit) |
| Renews | When your GLM Coding Plan's current period ends. Reads **Ends** when auto-renew is off. Enabled by default, tucked below the caret |

When Z.ai reports your plan name, OpenUsage shows it beside the provider name.

The **Renews** row comes from the same subscription response as the plan name, so it costs no
extra request. It follows the global **Reset Times** setting: `Renews in 88d 6h` on Countdown,
`Renews Nov 23` on Exact Time. With auto-renew turned off the row reads **Ends** on that date, and
an account with no active subscription entry shows no row at all.

## Where credentials come from

Z.ai has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API key.
OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

You can also add and rotate the key from **Settings → API Keys** without touching a file. Either
way, nothing leaves your Mac except the same API calls Z.ai's own subscription UI makes.

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list).
2. Add the key to OpenUsage via **Settings → API Keys**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. Z.ai appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

Two undocumented internal endpoints Z.ai's own subscription UI uses (stable in practice):

- `GET https://api.z.ai/api/biz/subscription/list` — plan name and the renewal date (best-effort; a
  failure here doesn't blank the meters).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — the quota meters.

The quota response carries a `limits` array. Each `CREDIT_LIMIT` entry (called `TOKENS_LIMIT` in
older responses) is a percentage quota window; its window length decides which meter it feeds
(sub-daily → Session, multi-day → Weekly), while a `TIME_LIMIT` entry is the monthly web-search
count. Reset times come back as epoch milliseconds. Missing required usage values are reported as
an invalid response instead of being shown as zero.

The subscription response is a list, so the renewal row picks the entry Z.ai marks as the running
period (`status: VALID`, `inCurrentPeriod`) and reads its `nextRenewTime`. That date is a bare
calendar day with no time zone, so OpenUsage shows the same day Z.ai's own dashboard does; the
countdown can therefore be a few hours out, which doesn't matter for a date that moves once a
billing period.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Settings → API Keys, or export `ZAI_API_KEY`.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [Z.ai console](https://z.ai/manage-apikey/apikey-list).
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe at [z.ai/subscribe](https://z.ai/subscribe);
  usage appears once your plan is active.
- **Meters show "No usage data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. Check your [plan](https://z.ai/manage-apikey/coding-plan/personal/my-plan).
