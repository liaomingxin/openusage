# Cursor

Tracks your Cursor plan usage using the native Cursor login and additional accounts signed in through OMP.

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

## OMP accounts

OpenUsage discovers active Cursor logins in OMP's local account database
(`~/.omp/agent/agent.db`, provider `cursor`) when it starts. It compares account IDs with the native
Cursor login, keeps that existing card, and adds one card for each other account. Additional cards
use the OMP email as their label and require no separate setup.

Each card reads only its own OMP access token. OpenUsage never reads OMP's refresh tokens, refreshes
them itself, or writes OMP's database. Update an expired login in OMP; the next refresh reads the
updated token. Restart OpenUsage to discover newly added or removed accounts.
Usage history stays separate by Cursor user ID.


## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage history—the same data shown on Cursor's Usage page. The cache read and cache write token counts show on the model breakdown. Pi and other local agents are not added on top of this account history. OpenUsage keeps each day on your Mac, separately for each Cursor account, and re-checks today and yesterday on every refresh. It fills in missing older days in the background within 20 seconds per refresh. A failed or short download never erases stored days. The chart appears once all 30 days are stored; heavy accounts may take a couple of refreshes the first time.

## Troubleshooting

- **Native card: "Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **OMP card: expired or missing login** — update that account in OMP. Restart OpenUsage if the account was removed and added again.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.
- **Payment warning you don't expect** — the triangle only follows what Cursor's billing data says. Check the payment method on your Cursor dashboard; the warning clears on the next refresh once Cursor stops reporting a problem.

## Under the hood

Connect RPC on `api2.cursor.sh` provides dashboard usage and Grok Bot usage. REST fallback uses
`cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts. Stripe account
data comes from `cursor.com/api/auth/stripe`, and paged history from
`cursor.com/api/dashboard/get-filtered-usage-events`.

Native credentials refresh and retry once after a 401/403. OMP cards instead report an OMP login
error without refreshing or trying another account. Optional endpoint failures stay nonfatal when
primary usage is available. Per-day spend is priced through the shared [model pricing](../pricing.md);
Cursor-native models come from its supplement layer.
