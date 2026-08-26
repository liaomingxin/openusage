# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits — a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"), and tucked below the "show more" caret by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (e.g. `2 available`) with a colored dot for the soonest expiry; hover the value for a timeline of each credit's expiry |
| Extra Usage | Flex credits, shown verbatim as dollars + credits (e.g. `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |
| Renews | When your ChatGPT subscription's current period ends. Enabled by default, tucked below the caret |

When Codex reports your plan name, OpenUsage shows it beside the provider name.

The **Renews** row follows the global **Reset Times** setting: `Renews in 20d 6h` on Countdown,
`Renews Sep 26` on Exact Time. It comes from the Codex login already on your Mac — no request is
made for it. That saved value only changes when the login refreshes (roughly every 10 days), so a
period that has already ended is carried forward a whole period at a time and the row is labeled
**Estimated** underneath. API-key-only logins carry no subscription date, so they show no row.

## Where credentials come from

Sign in once with the Codex CLI (`codex`); OpenUsage reads the same auth files (`$CODEX_HOME` respected) with a keychain fallback. Tokens refresh automatically and rotate back into the auth file.

Extra ChatGPT logins dumped under `~/.cli-proxy-api` (`codex-*.json`) are picked up too. Each file that names a *different* ChatGPT account becomes its own Codex card. The card is titled plainly **Codex** — hover the title to see the account's email. Everywhere else the name stands on its own (the menu bar, Customize, Total Spend, share cards, the local API) the card is named `Codex — extra@example.com` so the two stay apart. A dump of the same account that's already signed in at the default Codex home does not add a second card. Extra cards are tied to the original Codex card: they show the same metric rows, in the same order, with the same Always Visible / On Demand split — customize Codex once and every account follows. Each extra card still gets its own menu-bar stars: a fresh install (or that card's Reset) pins its Session and Weekly, and the 2-stars-per-provider cap counts per card. Live subscription meters (Session, Weekly, Spark, credits, resets) come from that login's usage API; Today / Yesterday / Last 30 Days and Usage Trend stay empty unless that login also has Codex session logs.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Codex CLI's session rollouts under `~/.codex/sessions/` and `archived_sessions/` (or `$CODEX_HOME`) itself — no external tools needed. Symlinks are followed, so a Codex home linked into a synced location (say, a Dropbox folder) is read all the same. Codex usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too: OpenUsage reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Codex usage there into the same tiles and trend. pi records its own per-message cost, so those dollars come straight from pi rather than being re-estimated. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); sessions that ran on the fast/priority service tier — as recorded in each session's own log — use the fast rates for exactly those turns. Older logs without tier metadata, and everything else, price at standard rates; the current `config.toml` setting is not consulted, so flipping the tier never reprices past days. Auto-review usage keeps its `codex-auto-review` name in the model breakdown, while its cost uses the dated model fallback available for that event. The token counts themselves are measured. Subagent and forked sessions copy their parent session's token history into their own log; OpenUsage recognizes those copies and counts each token once, no matter how many subagents a session spawns. No log data leaves your Mac.

For supported GPT-5.4, GPT-5.5, and GPT-5.6 models, requests above 272k input tokens use OpenAI's long-context rates for the whole request. Daybreak Blue usage is priced as GPT-5.6 Sol, matching OpenAI's published alias and Daybreak pricing. Cached input uses the published cache-read discount when the pricing source provides one; otherwise it is estimated at the full input rate. Fast/priority estimates use each model's published Codex multiplier (for example, GPT-5.5 uses 2.5×); model names ending in `-fast` are normalized to their unscaled base rate before that multiplier is applied once.

## Troubleshooting

- **"Not logged in"** — run `codex` and sign in, then refresh.
- **API-key-only setups** can't read subscription usage — sign in with your ChatGPT account instead.
- **Spend tiles show "No data"** — OpenUsage found no Codex session logs in the last 30 days. If your Codex home lives somewhere custom, set `CODEX_HOME` so both the Codex CLI and OpenUsage look in the same place.

## Under the hood

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token; refresh via `auth.openai.com`. A 401/403 triggers one token refresh and retry. Session and Weekly are classified by each usage window's duration rather than by its primary/secondary slot. This matters when Codex temporarily removes one limit and moves the remaining weekly window into the primary slot. Payloads without a recognized duration retain the primary-as-Session and secondary-as-Weekly compatibility fallback; response headers fill percentages missing from the corresponding window.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array — model-specific limits that reuse the duration-based Session/Weekly classification. OpenUsage surfaces the entry whose name identifies GPT-5.3-Codex-Spark as those two meters; accounts without the limit simply omit the entry, so the rows read "No data". Other model limits in that array aren't shown.

OpenUsage preserves Codex's reported `used_percent` verbatim. If the API reports 1% used for an untouched window, the app shows 99% left; if it reports 0%, the app shows 100% left. Codex rows use the normal reset label rather than inferring a special "Not started" state. Burn-rate pacing still waits until enough of the window has elapsed to make a useful projection.

The "Renews" row is a pure local read: the Codex login file OpenUsage already opens carries the paid period's start and end, so no ChatGPT endpoint is called and no token refresh is triggered for it. OpenAI's own routes that used to carry a subscription date are unreachable to a non-browser client, and OpenUsage does not spend a token refresh just to freshen a display value — hence the roll-forward and the **Estimated** label. Each extra Codex card reads its own login file, so every account shows its own date (or no row, when that login has none).

The "Rate Limit Resets" row shows the on-demand reset-credit count, e.g. `2 available`, with a colored dot for the soonest credit's expiry — blue beyond a week, yellow within a week, red within 48 hours. OpenUsage also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call — the dedicated endpoint that lists each credit's expiry — and surfaces those in a popover when you hover the value: a timeline of each reset, soonest-first — a numbered color dot, the exact expiry time (`Jul 12 at 5:30 PM`), and the countdown to it (`12d 18h`) on the trailing edge. When no credits are available it reads `0 available` and the popover shows `You have no rate limit resets`. If the dedicated call fails, the row falls back to the count embedded in the usage body (`rate_limit_reset_credits.available_count`); since that body carries no per-credit expiries, the popover states the count (`N available`) and notes that expiry times are unavailable rather than implying there are none.

### Using a reset from the popover

You can also spend a reset credit right from that popover — the same claim the Codex CLI's "Usage limit resets" picker performs. Hover a credit in the timeline and a **Use** button appears; clicking it expands that credit into an inline confirmation ("Immediately reset your usage limits. This can't be undone.") with **Reset** / **Cancel**. Confirming claims that exact credit and immediately resets your 5-hour and weekly windows; the app then refreshes Codex so the meters and the remaining count reflect it before the success line ("Reset claimed. Enjoy!") appears.

Safeguards, because a claim is irreversible:

- Claiming is always a deliberate two-click flow behind the hover popover — nothing is ever claimed automatically.
- Each claim targets one explicit credit (re-matched against a fresh credit list at claim time) and carries an idempotency key, so a retry after a network error can never spend a second credit.
- If the credit was meanwhile used elsewhere (CLI or web) the popover says it's no longer available and refreshes; if your usage doesn't need a reset, Codex refuses without spending the credit and the popover says so. After a claim resets usage, the remaining Use buttons disable ("nothing to reset") until the popover is reopened.
