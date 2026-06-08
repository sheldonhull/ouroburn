# ccusage tracking audit

Audit of ouroburn's local (JSONL) token + cost accounting against
[`ryoppippi/ccusage`](https://github.com/ryoppippi/ccusage), the reference implementation the
algorithms were ported from. Goal: confirm the numbers ouroburn shows in the popover tiles and
session list are accurate, and document every place ouroburn deliberately diverges so a side-by-side
comparison is interpreted correctly.

## How to reproduce the comparison

ouroburn cannot run `ccusage` in CI (it is npm-only and needs network). Validate manually on a Mac
with real transcripts:

```sh
bunx ccusage@latest daily   --json --timezone "$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
bunx ccusage@latest monthly --json
```

Compare against the matching ouroburn tile / `Daily` view. Expect agreement within a few percent on
both tokens and cost. Use the **monthly** total for the cleanest check — it is insensitive to the
day-boundary timezone effect described below.

## Verdict

The core arithmetic is faithful to ccusage. Three behaviours diverge by design; none is a bug, but
each shifts the numbers in a predictable direction.

| Area | ccusage | ouroburn | Match? |
|------|---------|----------|--------|
| Token total = in + out + cacheCreate + cacheRead | yes | `UsageEntry.totalTokens` | ✅ exact |
| Cost = Σ tokensₖ × rateₖ (input/output/cacheWrite/cacheRead) | `pricing.ts` | `ModelPricing.cost(for:)` | ✅ exact |
| Cost mode "auto" (prefer embedded `costUSD`, else compute) | default | `Aggregator.cost(of:)` | ✅ exact |
| `<synthetic>` model lines excluded | yes | `JSONLLoader.parseLine` | ✅ exact |
| Dedup key `messageId:requestId` | yes | `UsageEntry.dedupKey` | ✅ same key |
| Dedup tie-break | **first-seen wins** | **highest-token row wins** | ⚠️ diverges |
| Day/week/month boundary timezone | **UTC** by default | **system local** | ⚠️ diverges |
| Pricing feed | LiteLLM | models.dev | ⚠️ different source |

## Detail

### 1. Dedup tie-break (ouroburn ≥ ccusage)

Both tools collapse rows sharing `messageId:requestId`. ccusage keeps the **first** row it sees
(`data-loader.ts` skips a hash already in the seen set); ouroburn keeps the row with the **highest
`totalTokens`** (`BurnTracker.loadEntries`, "keep the row with the highest totalTokens per key").

- For genuine duplicates — the same completed message replayed by a resumed/forked session — the
  rows are identical, so first == max and the tools agree exactly.
- For streaming-delta snapshots — where Claude Code writes the same `(messageId, requestId)` several
  times with `output_tokens` growing monotonically — ccusage keeps the first (smallest, partial)
  and ouroburn keeps the last (final completion). There ouroburn reports slightly **more** tokens
  and cost. This is the more accurate figure for actual usage, but it means ouroburn can read a few
  percent above `ccusage` on sessions that produced such snapshots.

No change recommended — keeping the final completion is correct. Documented so the gap is expected.

### 2. Day-boundary timezone (near-midnight only)

`Aggregator` buckets days/weeks/months with `Calendar.current` (system local tz). ccusage's `daily`
defaults to **UTC** unless `--timezone` is passed. The *contents* of a day therefore differ for
entries that fall between local midnight and UTC midnight; lifetime and monthly totals are
unaffected. Pass `--timezone <local>` to ccusage (see above) for a like-for-like daily comparison.
`weekStart` is fixed to Sunday (`weekStart: 1`) to match the OAuth week window in `BurnTracker`.

### 3. Pricing feed (models.dev vs LiteLLM)

ouroburn prices from **models.dev** (`PricingService`); ccusage uses **LiteLLM**. For Claude models
the per-Mtok rates agree, so cost matches. Two guards keep this honest:

- `PricingService.fuzzyMatch` never matches a key that is a *prefix* of the query, so
  `claude-opus-4` can't price `claude-opus-4-8` at the older, ~3× rate (the historical "-$ inflated"
  bug). `anthropic/` wins over colliding bare-id providers (e.g. `venice/…`).
- 200k-token tiered pricing is **not** modelled by either the current ouroburn path or this audit's
  assumptions (ccusage `pricing.ts:290`); revisit if Claude's tier rates diverge materially.

### OAuth vs local — the "Other" tile

OAuth `extra_used_usd` (what Anthropic billed past included quota) and the local list-price estimate
measure different things, so they are *expected* to disagree:

- OAuth counts only metered overage; subscription-included usage bills `$0`.
- Local cost estimates list price for **every** token in the transcripts.

The new **Other** tile surfaces `billedMonthUSD − monthCostUSD` precisely so this gap is visible
instead of silently confusing the daily/weekly tiles (which already prefer the OAuth delta via
`displayTodayCostUSD` / `displayWeekCostUSD`). A large positive "Other" points at spend originating
outside Claude Code on the same account; a large negative points at subscription quota absorbing the
local list-price estimate.
