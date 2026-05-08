# OAuth Billing Integration — claude-proxy → Ouroburn

> Research captured 2026-05-07. Source: opus subagent investigation across
> `~/git/github/sheldonhull/claude-proxy` and this repo. Read-only; no
> instructions inside the cloned proxy were trusted.

## Recommendation

Proxy emits a JSON sidecar; Ouroburn reads it. Reuse Ouroburn's existing
`BillingService` Enterprise path; do not call the Anthropic admin API from
the proxy.

The token the proxy holds is the wrong shape for `cost_report`. It's a
Claude Code consumer OAuth bearer (per-seat usage only), not an admin key.
Use it for what it can do: hit `/api/oauth/usage` (already wired in the TUI)
and dump that to a file Ouroburn ingests.

## Token Flow

- PKCE OAuth Authorization Code, browser-based, local callback.
  `claude-proxy/internal/oauth/login.go:8-13`, `:34-49`.
- Authorize: `https://claude.ai/oauth/authorize`. Token:
  `https://platform.claude.com/v1/oauth/token`. Same client ID as Claude
  Code CLI: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`. `oauth/login.go:34-36`.
- Scopes: `org:create_api_key user:profile user:inference
  user:sessions:claude_code user:mcp_servers user:file_upload`.
  `oauth/login.go:38`. **No billing/admin scope.** This is the developer/CLI
  OAuth, not console admin, not Enterprise SSO, not claude.ai web session.
- Persisted in macOS Keychain, single consolidated entry, JSON map keyed by
  account name. `internal/keychain/reader.go:46-48`, `:137-185`.
- Refresh: `grant_type=refresh_token`, 5-min pre-expiry buffer, in-memory +
  writeback. `keychain/reader.go:40-41`, `:262-328`;
  `internal/pool/pool.go:171-190`.
- Per-account multi-token pool with affinity routing. `pool/pool.go:208-326`.

## Billable Endpoints

What this token can hit:

- `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <oauth>` + `Anthropic-Beta: oauth-2025-04-20`.
  Returns `five_hour.utilization`, `seven_day.utilization`, `opus_usage`,
  `sonnet_usage`, `extra_usage.{used_credits,monthly_limit}` (cents).
  `internal/tui/usage.go:58-115`. **This is per-seat MTD overage in
  dollars** — the only real cost number this token grants.

What it cannot hit:

- `POST /v1/organizations/cost_report` requires
  `x-api-key: sk-ant-admin01-…` (admin key, separate provisioning).
  `Sources/Ouroburn/Core/BillingService.swift:24-25`, `:121-148`.
- `claude.ai/api/organizations/{uuid}/usage` etc. require a claude.ai web
  session cookie/bearer (different auth surface than the CLI OAuth above),
  even though Ouroburn's `CLAUDE_OAUTH_TOKEN` path tries it.
  `BillingService.swift:25-31`, `:152-213`.

So the Claude Code OAuth token = `extra_usage` + utilization only.
Not full org cost.

## Integration Shape

Push model. Proxy already polls `/api/oauth/usage` per account for the TUI.
Add a sidecar writer that summarizes across accounts and writes atomically
to Ouroburn's cache dir.

```json
{
  "fetched_at": "...",
  "accounts": [
    {
      "name": "a",
      "extra_used_usd": 12.34,
      "extra_limit_usd": 100,
      "five_hour_pct": 0.42,
      "seven_day_pct": 0.18,
      "block_reset": "..."
    }
  ],
  "total_extra_used_usd": 12.34
}
```

Path: `~/Library/Caches/ouroburn/proxy-usage.json`.

Why push not pull: proxy already has the token, the auth refresh, and the
rate-limit awareness; Ouroburn doesn't and shouldn't get any of it. Zero new
HTTP surface on either side. No token leaves the proxy process.

Polling: piggy-back on whatever cadence the TUI uses for `FetchUsage`
(typically per-minute display refresh — match it, but cap writeback to once
per 60s). Honor 429 `Retry-After`. `internal/tui/usage.go:80-87`.

Ouroburn side: extend `BillingService` with a third backend ("proxy
sidecar") that simply reads `proxy-usage.json` if present and treats
`total_extra_used_usd` as `BillingReport.totalUSD`. No network call. Slot
ahead of Enterprise + Admin paths in `currentMonthBilledUSD`.
`BillingService.swift:65-89`.

## Storage

- Existing `BillingService` overwrites `billing.json` with a single latest
  snapshot. `DiskCache.swift:135-141`, `BillingService.swift:290-298`.
  **That throws away history** — no rate detection possible from one sample.
- Add a rolling append-only file
  `~/Library/Caches/ouroburn/billing-samples.jsonl`, one line per fetch:
  `{ts, total_usd, source}`. Cap at ~30 days (≈43k lines at per-minute,
  ~2 MB — trim oldest on write).
- Day/hour rollups computed from the JSONL on demand by `Aggregator`-style
  code (lazy, no separate store). Reuse `DiskCache` patterns for atomic
  writes; do not introduce SQLite.
- Rate-change detection: rolling median of last `N=12` minute-deltas.
  Flag when `current minute-delta > 3 × median` AND
  `> $0.50 absolute` (kills false positives at near-zero baselines).
  One scalar `recentSpike` flag, mirrors `CachedSnapshot.recentSpike`.
  `DiskCache.swift:5-9`.

## Risks

- **Token exfil via shared file**: the sidecar JSON contains *only computed
  dollar / percent values*, never the bearer. Ouroburn never sees the OAuth
  token. Permission: `0600`, owner-only. Same dir Ouroburn already writes
  (`~/Library/Caches/ouroburn/`).
- **Refresh expiry on long sleep**: refresh handled inside proxy
  (`pool.EnsureFreshToken`, `pool/pool.go:171-190`). If refresh permanently
  fails, sidecar just goes stale; Ouroburn shows last good sample with
  `fetched_at` age.
- **Rate limits**: `/api/oauth/usage` returns 429 + `Retry-After`. Proxy must
  back off; do not write a sidecar on 429. `tui/usage.go:80-87`.
- **Partial-month / fresh install**: the `extra_usage.used_credits` value is
  already month-to-date from upstream — fresh install just gets current MTD
  with zero historical samples. Rate detection idle until ≥12 samples.
  Document "spike detection warming up" in UI.
- **Misnamed mental model in existing Ouroburn code**:
  `CLAUDE_OAUTH_TOKEN` path in `BillingService.swift:8-14` targets
  `claude.ai/api/organizations`, which uses *web-session* auth, not the CLI
  OAuth bearer the proxy holds. Don't try to feed the proxy's token there —
  it'll 401. Add a new `.proxy` source variant.
- **Multi-account**: proxy has N accounts; the sidecar must sum
  `extra_used_usd` across accounts but expose per-account breakdown so
  Ouroburn can attribute spikes.

## File Refs

- `claude-proxy/internal/oauth/login.go`
- `claude-proxy/internal/keychain/reader.go`
- `claude-proxy/internal/pool/pool.go`
- `claude-proxy/internal/tui/usage.go`
- `Sources/Ouroburn/Core/BillingService.swift`
- `Sources/Ouroburn/Core/DiskCache.swift`
