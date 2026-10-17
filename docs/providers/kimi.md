# Kimi Code

Tracks [Kimi Code](https://www.kimi.com) (Moonshot AI) subscription usage for coding plans — the
quotas the `kimi` CLI reports with its `/usage` command.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window quota (percentage) |
| Weekly | Weekly allowance for legacy plans, with its reset countdown |
| Monthly Total | Shared monthly membership quota; enabled and always visible by default, not pinned |
| Monthly Coding | Monthly coding quota; enabled and always visible by default, not pinned |
| Booster | Extra Usage wallet balance when the API supplies it |
| Today / Yesterday / Last 30 Days | Local tokens and estimated cost from the Kimi Code CLI, pi's `kimi-coding` provider, and OpenCode's official Kimi login. Only the default card includes these machine-local totals |

When Kimi reports your membership level, OpenUsage shows it beside the provider name (e.g.
"Advanced").

While the rolling 5-hour session window has no usage yet, the Session row reads **Not started** on
the trailing label instead of a reset countdown; hover explains that the session begins after your
first message. The Weekly meter always shows a normal reset countdown.

## Where credentials come from

The default card reuses the login the `kimi` CLI already made. It reads:

- `~/.kimi-code/credentials/kimi-code.json` — the OAuth tokens the CLI stores after `/login`
- `~/.kimi-code/region` — selects the API host (`cn` → api.kimi.com, `global` → api.kimi.ai)
- `~/.kimi-code/device_id` — sent on token refreshes, mirroring the CLI

The default CLI card refreshes its OAuth tokens and writes them back to the CLI's own credentials.
Additional cards use only the API key entered in OpenUsage; they never refresh or fall back to the
default CLI login.

## Add an account

The default CLI card needs no setup beyond installing Kimi Code and running `/login` once.
For additional cards:

1. Open **Customize → Kimi Code → Kimi Accounts → Add Account…**.
2. Paste a key from the **Kimi Code Console**, not the Moonshot Open Platform. A name is optional.
3. Leave the region as **China**, or select **Global** for an international account, then click **Add Account**.
4. Restart OpenUsage. Each added key gets its own card beside the automatic CLI card.

The cards share Kimi's metric layout, but have independent menu-bar pins, refreshes, and cached quotas.
Extra cards do not copy the default card's local spend history. The CLI accepts `openusage kimi` for all
Kimi cards or `openusage kimi@<id>` for one card.

OpenUsage saves each key privately for you. No file creation, file selection, or OAuth JSON import is
needed. Removing a card deletes its saved key. Additions and removals take effect after restart.

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

- Current responses contain `usages` ratios and reset times; legacy responses contain `usage` and
  `limits` counters. Both forms work. Missing monthly or weekly pools are not invented.
- If a summary ratio incorrectly reports zero while the matching legacy counter shows usage,
  OpenUsage keeps the nonzero counter.
- The legacy weekly meter defaults to a 7-day period when its response omits the window. Monthly
  resets are shown without assuming that every billing month has 30 days.
- The booster wallet's fixed-point millionth amounts are converted to dollars.
- Windows other than the 5-hour session in `limits[]` (daily caps and the like) exist in the API
  but aren't metered yet; `parallel.limit` (concurrent-request cap) isn't shown either.
