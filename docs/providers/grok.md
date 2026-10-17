# Grok

Tracks Grok Build credit usage using the Grok CLI login and additional accounts signed in through OMP.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens from completed Grok CLI sessions |
| Product Usage | Which Grok products used the pool this period, biggest share first (e.g. `4% Build · 1% Chat`) |

When Grok reports your subscription tier, OpenUsage shows it beside the provider name.

The weekly shared pool is the limit Grok enforces for unified-billing accounts (the old monthly credits meter is legacy and no longer shown). Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## OMP accounts

On launch, OpenUsage also discovers active Grok logins in OMP's local account database
(`~/.omp/agent/agent.db`, provider `xai-oauth`). An account already represented by the native Grok
login is not added again. Other accounts get separate cards, labeled with their OMP email.
No extra key entry, file selection, or login is needed.

OMP remains the owner of those logins: OpenUsage only reads the selected account's current access
token and never reads its refresh token or writes OMP's database. If the token expires, refresh or
sign in to that account in OMP; OpenUsage picks up the updated token on its next refresh.
New or removed accounts are discovered after restarting OpenUsage.


## Product Usage

Grok meters one shared pool across all of its products, so the Weekly tile alone can't say what used it. Product Usage breaks that same number down: one row listing each product and its share of the pool — Build (the CLI), Chat, Imagine, App Builder, and whatever xAI adds next. The list is whatever the billing response reports, so a new product shows up on its own.

Products that haven't used anything are left out, biggest share first. The percentages are shares of the same pool the Weekly tile measures, so they add up to it.

## The spend tiles

Only the native Grok card includes this Mac's local spend. Additional OMP cards show their own
remote quotas without duplicating the native card's log totals.


Today / Yesterday / Last 30 Days are computed **locally** from completed Grok CLI sessions under `~/.grok/sessions/` (or `$GROK_HOME/sessions/`). Grok usage from pi (`provider` `xai`) and from OpenCode's official xAI login is included. Proxy and custom gateways are not. This includes subagent, resumed, and forked sessions: their work is not necessarily included in the parent session's usage. Copies of the same completed event are counted once per model across session logs. OpenUsage uses the cost Grok recorded for each completed turn when available; older turns without a recorded cost are estimated using the shared [model pricing](../pricing.md). Days follow your Mac's local time zone, and each period shows cost and tokens together (`$4.08 · 1.2M tokens`). These amounts are separate from the credits reported by Grok's billing API, and no session data leaves your Mac. A period with no completed usage reads "No data" rather than `$0.00 · 0 tokens`.

## Troubleshooting

- **Native card: "Session expired" / auth errors** — run `grok login` again, then refresh.
- **OMP card: expired or missing login** — update that account in OMP. Restart OpenUsage if the account was removed and added again.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Product Usage shows "No data"** — nothing has used the pool this period yet, or the account predates Grok's per-product reporting. Use Grok for anything, then refresh.
- **Spend tiles show "No data"** — they need completed Grok CLI turns under `~/.grok/sessions/`; a turn that is still running has not been recorded yet. Finish a Grok CLI session, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` provides the weekly pool, pay-as-you-go
cap, and per-product split; `…/v1/settings` provides the plan name. Native CLI credentials refresh via
`auth.x.ai`, with one refresh-and-retry on 401/403. OMP cards never refresh tokens or try another
account after an authentication error.
