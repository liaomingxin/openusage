# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) GLM Coding Plan usage — quota meters plus your recent token,
call, and MCP-tool history.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage (percentage), with the credits behind it under the bar |
| Weekly | 7-day rolling window usage (percentage), with the credits behind it under the bar |
| Web Searches | Monthly web-search / web-reader / Zread allowance (used / limit). Below the caret |
| Usage Trend | Daily tokens over the last 30 days, as a small bar chart |
| Today / Yesterday / Last 30 Days | Tokens for the period, e.g. `66.1M tokens`, plus the API call count on token-metered plans (`66.1M tokens · 426 calls`). Below the caret |
| MCP Tools | MCP tool calls over the last 30 days, with a per-tool breakdown on hover. Below the caret |
| Renews | When your GLM Coding Plan's current period ends. Reads **Ends** when auto-renew is off. Below the caret |

When Z.ai reports your plan name, OpenUsage shows it beside the provider name.

**Session** and **Weekly** stay percentage meters — that is what Z.ai meters, and what a menu-bar pin
and the [local API](../local-http-api.md) export — but each row now also shows the raw figures behind
the percentage, e.g. `1,030 / 28,000 credits`, under the bar.

Hovering **Today**, **Yesterday**, or **Last 30 Days** opens the per-model breakdown for that period.
A GLM Coding Plan is a flat subscription, so nothing is priced: the panel ranks models by their share
of tokens rather than by cost. On credit-metered plans (every current Pro, Lite, Max, and Ultra
plan) Z.ai no longer reports call counts, so those rows carry tokens only; the numbers come from
the same accounting Z.ai's own usage page shows, including usage the per-model split can't
attribute.

**MCP Tools** reads the window's total (`27 calls`), and hovering it opens the same kind of
breakdown the period rows use — one line per tool Z.ai names, ranked by its share of the calls, e.g.
`Web Search MCP · 15 calls` above `Web Read MCP · 12 calls`. The list is whatever your plan enables,
so a tool Z.ai adds shows up on its own. A zero is a real measurement here — Z.ai reports the
window's tool totals directly — so a listed tool sitting at `0 calls` is shown as such. The token
rows work the other way: a period with no usage shows **No data** rather than a confident
`0 tokens`. On the rare response that names no tools, the row falls back to the three counts Z.ai
also reports (`1 search · 3 reads · 0 ZRead`).

The **Renews** row comes from the same subscription response as the plan name, so it costs no
extra request. It follows the global **Reset Times** setting: `Renews in 88d 6h` on Countdown,
`Renews Nov 23` on Exact Time. With auto-renew turned off the row reads **Ends** on that date, and
an account with no active subscription entry shows no row at all.

## Global or China platform

Z.ai publishes the same API on two consoles, and an account lives on exactly one of them:

| Platform | Console | API host |
|---|---|---|
| Global | [z.ai](https://z.ai) | `api.z.ai` |
| China | [open.bigmodel.cn](https://open.bigmodel.cn) | `open.bigmodel.cn` |

Pick yours in **Settings → API Keys → Z.ai → Platform**. The choice is stored next to your key (see
below) and decides which host every request goes to, which console the card's **Dashboard** and
**API Keys** buttons open, and which console the error messages name. There is no fallback between
hosts: a key that belongs to the other platform fails with a clear error rather than being retried
somewhere else.

New keys default to Global, which is what every setup before this option used.

## Where credentials come from

Z.ai has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API key.
OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

The platform choice lives in the same JSON file, as `"platform": "global"` or `"platform": "cn"`.
A file with no `platform` field means Global. Both `apiKey` and `api_key` spellings are accepted, and
saving or clearing a key from Settings keeps your platform choice.

```json
{ "api_key": "…", "platform": "cn" }
```

You can add and rotate the key from **Settings → API Keys** without touching a file. Either way,
nothing leaves your Mac except the same API calls Z.ai's own subscription UI makes.

## Setup

1. Subscribe to a GLM Coding plan and get your API key — from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list) on Global, or the
   [BigModel console](https://open.bigmodel.cn/apikey) on China.
2. Add the key in **Settings → API Keys**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. If your account is on the China platform, switch **Platform** to China in the same card.
4. Z.ai appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

Six undocumented internal endpoints Z.ai's own usage dashboard uses (stable in practice), all on
your chosen host — `https://api.z.ai` or `https://open.bigmodel.cn`. Which family serves the history
rows depends on how the plan meters usage, read from the quota response:

- **Credit plans** (a `CREDIT_LIMIT` entry — every current plan) use the `credit-usage` family,
  the same endpoints Z.ai's own usage page reads for them.
- **Token plans** (the older `TOKENS_LIMIT` windows) keep the legacy `model-usage` / `tool-usage`
  pair.

| Endpoint | Feeds | Required? |
|---|---|---|
| `GET /api/monitor/usage/quota/limit` | Session, Weekly, Web Searches, and the routing above | Yes |
| `GET /api/biz/subscription/list` | Plan name and Renews | Best-effort |
| `GET /api/monitor/credit-usage/activity` | Usage Trend, Last 30 Days (credit plans) | Best-effort |
| `GET /api/monitor/credit-usage/usage-detail?usageType=MODEL` | Today, Yesterday, and every period's per-model breakdown (credit plans) | Best-effort |
| `GET /api/monitor/credit-usage/usage-detail?usageType=MCP` | MCP Tools (credit plans) | Best-effort |
| `GET /api/monitor/usage/model-usage` | Usage Trend, Today, Yesterday, Last 30 Days (token plans) | Best-effort |
| `GET /api/monitor/usage/tool-usage` | MCP Tools (token plans) | Best-effort |

Best-effort means a failure there is logged and leaves only its own rows empty — the quota meters are
never blanked by it. Each history call is also independent: one failing leaves the others standing.

The quota response carries a `limits` array. Each `CREDIT_LIMIT` entry (called `TOKENS_LIMIT` in
older responses) is a percentage quota window; its window length decides which meter it feeds
(sub-daily → Session, multi-day → Weekly), and its `currentValue` / `usage` pair is the credits shown
under the bar. A `TIME_LIMIT` entry is the monthly web-search count; plans that don't include one
simply show **No data** on that row. Reset times come back as epoch milliseconds. Missing required
usage values are reported as an invalid response instead of being shown as zero.

The credit endpoints answer in the same shape Z.ai's own page reads: `activity` reports the
account-wide daily series and window totals behind the trend and Last 30 Days (the widest
accounting, so the card matches what Z.ai's dashboard shows), `usage-detail` MODEL reports the
per-model buckets behind the breakdowns, and `usage-detail` MCP reports the per-tool call counts
behind MCP Tools. They also declare their bucket `timezone` and `granularity` explicitly; the legacy
endpoints don't, so those keep assuming the Beijing clock. The credit family reports no call
counts — Z.ai dropped the figure when it moved to credit metering — so credit-plan period rows
carry tokens only.

The subscription response is a list, so the renewal row picks the entry Z.ai marks as the running
period (`status: VALID`, `inCurrentPeriod`) and reads its `nextRenewTime`. That date is a bare
calendar day with no time zone, so OpenUsage shows the same day Z.ai's own dashboard does; the
countdown can therefore be a few hours out, which doesn't matter for a date that moves once a
billing period.

### Days and time zones

The history endpoints take a start and end time on Z.ai's own clock (Beijing time), so OpenUsage
formats its requests in that zone and reads the bucket labels back in it. On credit plans the
payload declares its `timezone` and the labels are read in whatever zone it names.

Z.ai chooses the bucket size: a range up to seven days comes back hour by hour, anything longer comes
back as whole Beijing days. That is why the history is fetched twice per refresh —

- a **30-day** call, in whole days, behind Usage Trend and Last 30 Days, and
- a **short** call, hour by hour, behind Today and Yesterday.

On credit plans the short call is `usage-detail` MODEL, whose hourly buckets include the hour still
in progress — so Today counts what has actually happened so far, not just completed hours.

Hourly buckets are added up into *your* Mac's calendar days, so Today and Yesterday mean your today
and yesterday wherever you are. Whole-day buckets are already complete days on Z.ai's calendar and are
shown as such, matching what Z.ai's own dashboard reports.

This history is the same on every Mac signed into the account, so — like Cursor's — it is never
merged across your Macs and never written to the [iCloud Sync](../icloud-sync.md) file.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Settings → API Keys, or export `ZAI_API_KEY`.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Check that **Platform** matches the
  console that issued the key, then regenerate it there if needed.
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe on the console the error names; usage
  appears once your plan is active.
- **Meters show "No usage data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. Check your plan on the card's **Dashboard** link.
- **The history rows are empty but the meters work** — one of the two history endpoints failed this
  refresh. It retries on the next pass; the reason is in the [log](../logging.md).
