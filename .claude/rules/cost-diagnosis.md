---
paths:
  - Sources/Ouroburn/Core/Billing*.swift
  - Sources/Ouroburn/Core/BurnTracker.swift
  - Sources/Ouroburn/Core/PricingService.swift
  - Sources/Ouroburn/UI/MetricsViewController.swift
---

# Cost-diagnosis

- OAuth-today = delta of MTD samples across local midnight (not raw MTD); compare like-for-like before blaming JSONL aggregation.
- OAuth windows (today/week) are reset-aware: `BurnTracker.oauthSpend` sums only positive consecutive MTD steps. Negative steps = billing-cycle reset (month rollover → MTD drops to ~$0) or a not-yet-recovered upstream trough; never count them as spend.
- `extra_used_usd` is month-to-date and resets at the billing boundary. A raw anchor-delta across that boundary yields a phantom negative (the "-$210" artifact). `BillingSampleStore.load` already strips *recovered* troughs; the positive-step guard covers genuine resets + the trailing trough.
- `$12.34` is a known recurring upstream glitch value (transient trough), not a real reading.
- Tiles + alerts read `displayTodayCostUSD` / `displayWeekCostUSD` (OAuth delta, JSONL fallback). Tokens stay JSONL (OAuth exposes none).
- JSONL cost wrong (not OAuth)? Suspect pricing resolution before dedup. `PricingService.fuzzyMatch` must never match a key that is a *prefix* of the query — `claude-opus-4` for `claude-opus-4-8` billed 3x legacy rates. Validate against `ccusage` (`bunx ccusage@latest daily --json`) as the JSONL reference; ouroburn should land within a few % on tokens + cost.
- Pricing cache `~/Library/Caches/ouroburn/pricing.json` (models.dev, 1-day TTL). Delete it to force a refetch when a newly released model resolves to $0 or a stale rate. `anthropic/` prefix wins over colliding bare-id providers (venice etc.).
