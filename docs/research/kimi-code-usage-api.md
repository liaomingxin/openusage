# Kimi Code Usage API: How the Subscription Meter Works

Research + live verification of the Kimi Code CLI's subscription-usage query, done
2026-08-25. Kimi Code is not yet an OpenUsage provider — this is the protocol
reference for adding one, in the same spirit as the Codex reset-credit notes.

Sources: static reverse engineering of the `kimi` 0.38.0 binary (Node SEA
single-executable, `packages/oauth/src/managed-usage.ts` and friends extracted
from the embedded bundle), plus a live end-to-end query against a real
logged-in account (identifiers below are redacted).

## What Kimi Code is

Moonshot's coding-agent CLI (`kimi`, "The Starting Point for Next-Gen Agents"),
installed under `~/.kimi-code/` with the binary at `~/.kimi-code/bin/kimi`.
Auth is OAuth-only for the managed `managed:kimi-code` provider; there is no
API-key path for subscription usage. The CLI surfaces usage via the `/usage`
slash command (TUI) and the "Plan Usage" submenu (local Web UI at
`kimi web`); both funnel into one service method that makes exactly one
upstream HTTP call.

## Where credentials come from

Everything lives under `~/.kimi-code/` (mode 600):

| File | Contents |
|---|---|
| `credentials/kimi-code.json` | `access_token`, `refresh_token`, `expires_at` (unix seconds), `expires_in`, `scope`, `token_type` |
| `device_id` | stable UUID sent as `X-Msh-Device-Id` on auth-server calls only |
| `region` | `cn` or `global` |
| `config.toml` | provider table with the OAuth ref (`oauth/kimi-code`) |

The access token lives **15 minutes** (`expires_in: 900`); any usage query must
be prepared to refresh first. `scope` is `kimi-code`.

## OAuth refresh

`POST https://auth.kimi.com/api/oauth/token`
(`application/x-www-form-urlencoded`):

```
client_id=17e5f671-d194-4dfb-9706-5516cb48c098
grant_type=refresh_token
refresh_token=<refresh_token>
```

Device-identity headers ride along on auth-server calls (but not on the usage
call): `User-Agent: kimi-code-cli/<version>`, `X-Msh-Platform: kimi_code_cli`,
`X-Msh-Version`, `X-Msh-Device-Id`, `X-Msh-Device-Name`, `X-Msh-Device-Model`,
`X-Msh-Os-Version`.

Retry policy: 3 attempts with exponential backoff (2^n s) on 429/5xx; an
immediate `OAuthUnauthorizedError` on 401/403/`invalid_grant` (the CLI tells
the user to `/login` again). First-time login is a device-code flow
(`POST /api/oauth/device_authorization`, then poll `/api/oauth/token` with
`grant_type=urn:ietf:params:oauth:grant-type:device_code` every ~5 s).
`KIMI_CODE_OAUTH_HOST`/`KIMI_OAUTH_HOST` override the auth host; non-default
(base URL, oauth host) pairs are stored under sha256-scoped credential keys
rather than the default `kimi-code.json` slot.

## The usage endpoint

One call, no signature, no body:

```
GET https://api.kimi.com/coding/v1/usages        # note the plural
Authorization: Bearer <access_token>
Accept: application/json
```

- Base URL default `https://api.kimi.com/coding/v1`; overridable via
  `KIMI_CODE_BASE_URL` (a global region file flips the default host between
  `api.kimi.com` and `api.kimi.ai`).
- 8-second client-side timeout (AbortController).
- Error mapping in the CLI: 401 → "check your API key (try /login)"; 404 →
  "usage endpoint not available, try Kimi For Coding"; network/timeout →
  generic error. Error bodies are mined for `error_description` / `message` /
  `detail` (top level or nested under `error`/`errors`).

### Live response (CN subscriber, redacted)

```json
{
  "user": {
    "userId": "cno2i0ilnl93bcsjk4***",
    "region": "REGION_CN",
    "membership": { "level": "LEVEL_ADVANCED" },
    "businessId": ""
  },
  "usage": {
    "limit": "100",
    "used": "79",
    "remaining": "21",
    "resetTime": "2026-08-28T03:18:21.328791Z"
  },
  "limits": [
    {
      "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
      "detail": {
        "limit": "100",
        "remaining": "100",
        "resetTime": "2026-08-25T07:18:21.328791Z"
      }
    }
  ],
  "parallel": { "limit": "30" },
  "totalQuota": {},
  "authentication": { "method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING" },
  "subType": "TYPE_PURCHASE",
  "domain": "DOMAIN_NEXUS"
}
```

Notes on the shape:

- All numbers arrive as **strings**; the CLI accepts string-or-number.
- `usage` is the headline quota. When the response omits a window on it, the
  CLI assumes `{duration: 1, unit: "week"}` — i.e. a weekly allowance.
- `limits[]` are fine-grained windows keyed by duration
  (`TIME_UNIT_MINUTE|HOUR|DAY|WEEK`); the CLI normalizes whole-hour minute
  values (300 min → 5 h) and renders at most the first five rows. The Web UI
  specifically picks the 5-hour row for display.
- `boosterWallet` (absent on subscription accounts) is the pay-as-you-go
  wallet: `balance.type == "BOOSTER"`, `amount`/`amountLeft` are **fixed-point
  millionths** divided by 1e6 into cents, plus `monthlyChargeLimit` /
  `monthlyUsed` money objects and `monthlyChargeLimitEnabled`; currency
  defaults to USD when absent.
- `parallel.limit` is the concurrent-request cap.
- `subType: TYPE_PURCHASE` marks a subscription; pay-as-you-go accounts
  surface the booster wallet instead.

### Client parsing (verbatim from `managed-usage.ts`)

- `usage` → summary row `{name?, window?, used, limit, resetAt}`; `used`/`limit`
  fall back to 0, `resetTime` maps to `resetAt`.
- Each `limits[]` entry → `{name: <entry name or detail name>, window,
  used: limit-remaining? …}` — the CLI reads `detail.used` (falling back to 0)
  and `detail.limit`; `remaining` is kept by the server but the CLI works from
  used/limit.
- Missing both `used` and `limit` drops the row.

## Mapping to OpenUsage metrics

A first pass at the provider contract, for whenever this gets implemented:

| Kimi field | OpenUsage metric |
|---|---|
| `usage.used/limit` + `resetTime` | `.progress(.percent)` weekly meter with `resetsAt` |
| 5-hour entry in `limits[]` | `.progress(.percent)` session meter, classified by `window.duration` (300 min) exactly like Codex |
| `boosterWallet.balanceCents/totalCents` | `.progress(.dollars)` or `.values` for pay-as-you-go balance |
| `parallel.limit` | `.values` or omit |
| `membership.level` | snapshot `plan` (e.g. "Advanced") |

`hasLocalCredentials()` maps cleanly: existence of
`~/.kimi-code/credentials/kimi-code.json` with a refresh token.

## Endpoint summary

| Call | Method & URL | Auth |
|---|---|---|
| Refresh | `POST https://auth.kimi.com/api/oauth/token` | refresh-token grant + device headers |
| Usage | `GET https://api.kimi.com/coding/v1/usages` | `Bearer <access_token>` only |
| User info | `GET https://api.kimi.com/coding/v1/me` (returns `user_id`, nickname/avatar, membership; used for the CLI's account menu) | same |

## Caveats for implementation

- Token expiry is 15 minutes — always refresh-on-401 (and pre-emptively when
  `expires_at` has passed) rather than caching the access token.
- The refresh response **rotates the refresh token**; write the new pair back
  or the next refresh dead-ends with `invalid_grant`.
- Numeric strings: parse defensively (`toInt` accepts both).
- `resetTime` is RFC3339 with microseconds; OpenUsageISO8601 handles it.
- The `usages` plural is not a typo — singular 404s.
