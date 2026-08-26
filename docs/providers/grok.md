# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

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

## Product Usage

Grok meters one shared pool across all of its products, so the Weekly tile alone can't say what used it. Product Usage breaks that same number down: one row listing each product and its share of the pool — Build (the CLI), Chat, Imagine, App Builder, and whatever xAI adds next. The list is whatever the billing response reports, so a new product shows up on its own.

Products that haven't used anything are left out, biggest share first. The percentages are shares of the same pool the Weekly tile measures, so they add up to it.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from completed Grok CLI sessions under `~/.grok/sessions/` (or `$GROK_HOME/sessions/`). Subagent usage is counted through its parent session, so parallel tasks do not inflate the totals. OpenUsage uses the cost Grok recorded for each completed turn when available; older turns without a recorded cost are estimated using the shared [model pricing](../pricing.md). Days follow your Mac's local time zone, and each period shows cost and tokens together (`$4.08 · 1.2M tokens`). These amounts are separate from the credits reported by Grok's billing API, and no session data leaves your Mac. A period with no completed usage reads "No data" rather than `$0.00 · 0 tokens`.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Product Usage shows "No data"** — nothing has used the pool this period yet, or the account predates Grok's per-product reporting. Use Grok for anything, then refresh.
- **Spend tiles show "No data"** — they need completed Grok CLI turns under `~/.grok/sessions/`; a turn that is still running has not been recorded yet. Finish a Grok CLI session, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for the weekly pool, the pay-as-you-go cap, and the per-product split (all three come from that one response, so the breakdown costs no extra request) — the exact call the Grok CLI itself makes — and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
