# ouroburn

macOS menu bar app that tracks Claude Code token burn rate.
Snake eats its tail faster as you spend more.
Color shifts blue → red as the rate climbs.

## What it does

- Polls Claude Code transcript JSONL files (`$CLAUDE_CONFIG_DIR`,
  `$XDG_CONFIG_HOME/claude/projects/**`, `~/.claude/projects/**`) once per minute.
- Aggregates tokens and cost across five view modes — daily, weekly, monthly,
  5-hour billing block, and per-session — with per-model breakdown.
- Drives an animated ouroboros icon: rotation speed and heat color scale linearly
  with the trailing 5-minute token rate.
- Surfaces spikes through `UNUserNotificationCenter` (rate doubled and exceeds
  500 tok/min, throttled to one alert per 10 minutes).
- Caches the most recent snapshot to `~/Library/Caches/ouroburn/snapshot.json`
  so the popover has data the moment you open the app, even offline.
- Caches LiteLLM pricing data to `~/Library/Caches/ouroburn/pricing.json` with a
  24-hour TTL; falls back to the cached copy when the feed is unreachable.

## Why

AI agents burn money. Watch it happen.

## Build & run

Requires macOS 14+ and the Xcode toolchain (Swift 6).

```sh
mise install      # installs hk, pkl, task, swiftformat, swiftlint
mise run build    # release build
mise run run      # debug run (menu bar icon appears in the status area)
mise run test     # 29 swift-testing cases across loader, aggregator, blocks, pricing
mise run lint     # swiftlint
mise run fmt      # swiftformat
```

The `test` task includes the rpath flags needed when running on Command Line
Tools without a full Xcode install. With Xcode present, plain `swift test`
also works.

## Layout

```
Sources/Ouroburn/
  main.swift                    entry point — accessory activation policy
  AppDelegate.swift             wires tracker + status bar + notifier
  Models/
    UsageEntry.swift            normalized JSONL line
    ModelBreakdown.swift        per-model aggregation row
    AggregateBucket.swift       unified bucket shape across view modes
    ViewMode.swift              day | week | month | sessionBlock | session
  Core/
    JSONLLoader.swift           getClaudePaths port + streaming parse + dedup
    PricingService.swift        LiteLLM feed fetch, prefix lookup, disk cache
    SessionBlockBuilder.swift   5-hour Claude billing window algorithm
    Aggregator.swift            day/week/month/session bucketing + cost calc
    DiskCache.swift             snapshot persistence for offline bootstrap
    Notifier.swift              throttled spike notifications
    BurnTracker.swift           60-second poll loop, snapshot orchestrator
  UI/
    StatusBarController.swift   NSStatusItem + popover toggle
    OuroborosView.swift         hand-drawn animated snake biting tail
    MetricsViewController.swift segmented control + table popover

Tests/OuroburnTests/
  JSONLLoaderTests.swift        parse/reject/dedup/cutoff/path-resolution
  AggregatorTests.swift         day/week/month/session/model-breakdown
  SessionBlockBuilderTests.swift gap, active, UTC floor, window split
  PricingServiceTests.swift     decode/lookup/cost/disk-cache round trip
  Fixtures/                     sample.jsonl + pricing.json
```

## Open work

- Spike notification copy could include cost-per-hour delta vs. previous window.
- 200k-token tiered Claude pricing is not yet honored (ccusage `pricing.ts:290`).
- Popover does not yet show the active 5-hour block as a progress strip.
- No filesystem-watch fast path — every poll re-walks the projects directory.

## Credits

Algorithms ported from [`ryoppippi/ccusage`](https://github.com/ryoppippi/ccusage)
(MIT). The tool itself is npm-only; we read transcripts directly to keep the
menu bar polling cycle self-contained and offline-capable.

## License

MIT
