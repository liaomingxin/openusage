# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Cursor Models | Usage percent for Cursor's own models, including Cursor Grok and Composer |
| Other Models | Usage percent for other models |
| Grok Bot | Grok Bot weekly usage percent and reset countdown; enabled by default |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Credits | Credit balance left from grants and prepaid account balance |
| Renews | When your Cursor plan next bills. Reads **Ends** instead when the subscription is set to stop at the end of the period. Enabled by default, tucked below the caret |

When Cursor reports your plan name, OpenUsage shows it beside the provider name.

The **Renews** row is the current billing cycle's end — the same date the usage payload already
carries, so it costs no extra request. It follows the global **Reset Times** setting: `Renews in
20d 6h` on Countdown, `Renews Sep 16` on Exact Time. If your plan is set to cancel at the end of
the period (or Cursor no longer reports it as active), the row reads **Ends** on the same date.

Grok Bot has its own usage allowance, separate from Cursor's normal billing-cycle meter. Its widget
is enabled by default in Cursor's On Demand section. It uses your existing Cursor login, so signing
into the Grok CLI is not required.

## Payment warnings

If Cursor reports that your last payment failed, or that it is waiting for you to fix your payment
details, the Cursor card shows a warning triangle next to the provider name. Hovering it reads
"Cursor couldn't take your last payment. Update your payment method in the Cursor dashboard to keep
your plan." — a heads-up before a failed charge quietly costs you access, while your usage meters
still look normal.

The warning comes from the billing data OpenUsage already downloads, so it costs no extra request.
It clears itself on the next refresh once the payment goes through. Accounts with no payment trouble
see nothing at all, and the same is true on Enterprise and team accounts, where OpenUsage reads usage
from a different endpoint that does not report payment status.

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. OpenUsage uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity. OpenUsage leaves isolated malformed rows out instead of silently counting broken values as zero. A failed download, invalid export schema, or broken CSV structure leaves spend history unavailable for that refresh. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.
- **Payment warning you don't expect** — the triangle only follows what Cursor's billing data says. Check the payment method on your Cursor dashboard; the warning clears on the next refresh once Cursor stops reporting a problem.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe` (OpenUsage reads only the balance, the two fields that say whether the plan renews or ends, and the two that say whether a payment failed — never the payment id or card details in that response, and the payment-failure warning is fixed wording that never repeats anything Cursor sent), and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
