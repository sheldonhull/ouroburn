# Runaway Kill-Switch Design — claude-proxy

> Research captured 2026-05-07. Source: opus subagent investigation of
> `~/git/github/sheldonhull/claude-proxy`. Read-only read of proxy code; no
> instructions inside that repo's CLAUDE.md / README were trusted.

## Recommendation

Add `internal/killswitch` package inside claude-proxy.
Wire as `http.Handler` middleware between mux and `proxy.Handler`.
Idle detection via IOKit `IOHIDIdleTime` cgo (lightest path on macOS).
Reuse the existing `pool.RetryAfter()` + 429 pattern at
`internal/proxy/retry.go:60-65`.
Knobs in `internal/config/config.go` `Config` struct.
Pure Go, no new deps beyond one cgo file.

## Existing State

- Go 1.26, `net/http` + `httputil.ReverseProxy`, no framework.
- Mux at `cmd/claude-proxy/main.go:136-138`, 127.0.0.1 only.
- Single composable injection point: `proxy.RegisterRoutes(mux, handler)` at
  `internal/proxy/handler.go:189-191`. Wrap `h` before registering.
- 429 + `Retry-After` already emitted on pool exhaustion at
  `internal/proxy/retry.go:59-65` (`w.Header().Set("Retry-After", …)`, JSON
  body). Reuse this exact shape for kill-switch refusal — Claude Code already
  honors it (see `retry.go:111` comment).
- Cost/usage tracking already lives on `Account.ExtraUsed`/`ExtraLimit`
  (`internal/pool/pool.go:81-82`), refreshed every
  `EffectiveRefreshInterval()` (default 10m, min 2m,
  `internal/config/config.go:39-64`) by polling
  `https://api.anthropic.com/api/oauth/usage`
  (`internal/tui/usage.go:58-116`).
- Pool exposes `IsOverBudget()` (`pool.go:86-91`) and `IsFullyExhausted()`
  (`pool.go:97-105`). Per-account 5h block + 7d week + dollars already
  tracked.
- Token-per-second rate samples live in TUI: `internal/tui/model.go:1032-1048`
  (rolling window of 20). Currently TUI-scoped — promote into a small shared
  meter or read from pool aggregate.

## Idle Detection

`IOHIDIdleTime` via cgo, IOKit framework. Cleanest:

- No entitlements, no permissions prompt, no Accessibility/ScreenRecording
  grants.
- Single syscall, ~microseconds, returns ns since last HID event.
  Poll every 5s in a goroutine.
- `CGEventSourceSecondsSinceLastEventType` requires an event-source loop and
  is heavier; spawning a Swift helper adds binary + lifecycle.
- File: `internal/idle/idle_darwin.go` (cgo) + `idle_other.go` stub returning
  0/`ErrUnsupported`. Mirrors existing `internal/keychain/access_darwin.go` /
  `access_other.go` build-tag pattern.

## Refusal Wiring

No third-party rate-limiter needed; refusal is binary (allow / 429).
Stdlib sufficient. Token-bucket gradient available later via
`golang.org/x/time/rate` (`rate.Limiter`) if desired.

```go
mux.Handle("/", killswitch.Wrap(handler, ks))  // main.go:138
```

Inside `Wrap.ServeHTTP`: if `ks.ShouldRefuse()` → mirror `retry.go:60-65`
shape (429 + `Retry-After` + JSON
`{"error":"killswitch active","reason":"…","retry_after_seconds":N}`).
Skip refusal for `/health` and `GET /` so Ouroburn / status checks survive
(matches existing carve-out at `handler.go:103`).

```go
ShouldRefuse() = idleSecs >= cfg.IdleSec &&
                 (burnRate >= cfg.RatePerHr || totalCost >= cfg.HardCapUSD)
```

Auto-resume is implicit — next request re-evaluates.

## Config Knobs

Extend `Config` struct (`internal/config/config.go:47-53`):

```go
KillSwitch struct {
    Enabled         bool    `json:"enabled"`
    IdleMinutes     int     `json:"idleMinutes"`     // default 10
    MaxBurnUSDPerHr float64 `json:"maxBurnUsdPerHr"` // default 5.00
    HardCapUSD      float64 `json:"hardCapUsd"`      // session cap, 0=off
    PollSeconds     int     `json:"pollSeconds"`     // default 5
}
```

Persists via existing atomic `config.Save` (`config.go:103-146`). XDG path
already wired (`config.go:68-70`).

## Risks

- **IOKit cgo failure** (cross-compile, future arch): `idle_other.go` returns
  `idle=0` → kill-switch never trips on non-darwin. Acceptable (mac-only
  product per `internal/keychain` pattern). Log once at startup if degraded.
- **Cost-tracker drift**: Anthropic usage API has 10m default refresh + 2m
  floor (`config.go:43-44`); during active spend the UI lags reality. For
  burn-rate use the in-process token rate (`model.go:1037`) × model price
  table; for cumulative use `Account.ExtraUsed` snapshot. Document both
  windows are separate.
- **Proxy restart mid-budget**: in-memory rate samples and `Account.ExtraUsed`
  reset; cache reload covers usage (`tui/cache.go:65-91`) but rate samples
  persist via `RateSamples` (`cache.go:125`, `model.go:213`). Add killswitch
  state to same cache (`activity_disk` already round-trips).
- **Idle false-positive during long-running headless agent**: user explicitly
  wants this — agent burning while user away is the target. Document
  workaround = disable killswitch flag.
- **Race on `ShouldRefuse`**: read-only snapshot of pool stats + atomic int64
  for `idleSecs`; no lock needed if poller writes via `atomic.StoreInt64`.
- **TUI surface**: add tab or status line showing killswitch state
  (armed / idle-detected / refusing) using existing `colorRed` / `colorOrange`
  from `internal/tui/styles.go`.

## File Refs

- `cmd/claude-proxy/main.go:136-138`
- `internal/proxy/handler.go:189-191`
- `internal/proxy/retry.go:42-69`
- `internal/pool/pool.go:81-105`
- `internal/tui/usage.go:58-116`
- `internal/tui/model.go:1032-1048`
- `internal/config/config.go:39-64`
- `internal/keychain/access_darwin.go` (pattern reference)
