# Kimi Code

Tracks [Kimi Code](https://www.kimi.com) (Moonshot AI) subscription usage for coding plans — the
quotas the `kimi` CLI reports with its `/usage` command.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window quota (percentage) |
| Weekly | The headline weekly allowance (percentage), with its reset countdown |
| Booster | Pay-as-you-go booster wallet balance (only on non-subscription accounts) |

When Kimi reports your membership level, OpenUsage shows it beside the provider name (e.g.
"Advanced").

## Where credentials come from

Kimi Code's usage API is OAuth-only — there is no API-key path — so OpenUsage reuses the login the
`kimi` CLI already made. It reads:

- `~/.kimi-code/credentials/kimi-code.json` — the OAuth tokens the CLI stores after `/login`
- `~/.kimi-code/region` — selects the API host (`cn` → api.kimi.com, `global` → api.kimi.ai)
- `~/.kimi-code/device_id` — sent on token refreshes, mirroring the CLI

Access tokens live 15 minutes. OpenUsage refreshes them before they expire and writes the rotated
tokens back to the same file the CLI reads, so both stay in sync. If the session can't be refreshed
(the CLI logged in elsewhere and rotated the token), the provider asks you to run `kimi` and log in
again — the same remedy the CLI itself suggests.

## Setup

1. Install the [Kimi Code CLI](https://www.kimi.com) and log in once (`kimi` → `/login`).
2. Subscribe to a Kimi for Coding plan.
3. Open OpenUsage — the Kimi Code card appears automatically (the credential probe finds the CLI's
   login) and shows Session/Weekly on first launch.

No key entry, no login inside OpenUsage.

## Endpoints called

| Call | Method & URL |
|---|---|
| Usage | `GET https://api.kimi.com/coding/v1/usages` (or `api.kimi.ai` for the global region) |
| Token refresh | `POST https://auth.kimi.com/api/oauth/token` |

## Error states

| Message | Meaning |
|---|---|
| Not logged in. Run `kimi` and use /login to authenticate. | No CLI credential file found |
| Session expired. Run `kimi` and log in again. | Refresh token rejected (`invalid_grant`) or usage keeps answering 401 after a refresh — re-login in the CLI fixes it |
| Request failed (status) / Connection failed / Invalid response | Network or server problems; the next refresh retries |

## Notes

- Numbers arrive as strings over the wire; parsing accepts both strings and numbers, exactly like
  the CLI.
- The weekly meter defaults to a 7-day period when the response omits its window — the same default
  the CLI applies.
- The booster wallet's fixed-point millionth amounts are converted to dollars.
- Windows other than the 5-hour session in `limits[]` (daily caps and the like) exist in the API
  but aren't metered yet; `parallel.limit` (concurrent-request cap) isn't shown either.
