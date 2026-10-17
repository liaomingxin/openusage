# Muse Code

Tracks subscription quotas and local session token usage for Meta's Muse Code CLI (`muse`).

## What It Tracks

| Metric | Description |
|---|---|
| Session | Rolling 5-hour subscription usage window (`subs_usage.window`) |
| Weekly | Rolling 7-day subscription usage window (`subs_usage.weekly`) |
| Today / Yesterday / Last 30 Days | Token count and estimated USD spend from local `~/.local/share/muse/sessions/**/session.jsonl` logs |
| Usage Trend | 30-day daily token bar chart |

## Credentials

OpenUsage reads the login already saved by `muse login`:

1. `~/.config/muse/auth.json` (or `$MUSE_AUTH_PATH` / `$XDG_CONFIG_HOME/muse/auth.json`), under `providers.meta`.
2. When `storage` is `"keychain"`, OpenUsage reads the OAuth `access_token` from macOS Keychain (`service: "ai.meta.dev.credentials"`, `account: "meta"`).

## Endpoints

- `POST https://api.meta.ai/muse-code/key` with `Authorization: Bearer <access_token>` and `x-api-version: 1.0.0`.

## When Quotas Are Unavailable

Muse can return a successful response with an active subscription and plan name but no `subs_usage`
while the 5-hour window is idle. Session and Weekly then show **No data**, even if the weekly pool
has usage. This is not a login failure, and OpenUsage does not invent an unused allowance.
Local token counts and estimated spend remain available.

Quota reporting usually resumes when normal Muse activity starts another session window.
See the [upstream report](https://github.com/steipete/CodexBar/issues/4002).
