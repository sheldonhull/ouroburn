# Persistence design — proposal

Status: proposal.
Author: Overlord (Sheldon Hull collab).
Date: 2026-05-08.

## Problem

Cold start re-parses ~2,256 JSONL files (~7.8 GB) every launch.
Takes ~80–120 s on first poll.
In-memory `fileCache` (mtime-keyed) dies on quit, so every relaunch re-pays full parse cost.
`DiskCache` persists *aggregates* (buckets + timelines) but not raw entries or per-file metadata.
Result: bottom graphs and lists feel slow on first poll after relaunch even when nothing changed on disk.

## Goals

1. Cold start shows fully-rendered popover within ~2 s.
2. New JSONL writes still get picked up incrementally.
3. Force-refresh path nukes cache and re-parses from source.
4. Survives across upgrades — schema evolves cleanly.
5. Stays simple. Minimum dependencies. Minimum new abstractions.

## Non-goals

- Cross-machine sync.
- Querying historical data outside the running session window.
- User-facing data export (handled separately if needed).

## Options ranked simple → heavy

Each option has a "fit verdict" — the goal is to stop at the simplest one that works.

### Option A — extend DiskCache to persist `fileCache` (RECOMMENDED START)

**Idea**: keep current architecture.
Add a second JSON-or-binary-plist file at `~/Library/Caches/ouroburn/file-cache.bin`.
Persist `[URL: CachedFile]` (mtime + parsed entries) on graceful quit + every Nth poll.
Reload on launch. Skip JSONL parse for unchanged files.

**Pros**:
- Zero new dependencies.
- Minimal code change. ~150 LOC across `DiskCache` + `BurnTracker.start/stop`.
- Existing aggregate cache unchanged.
- Force-refresh: delete file. Same as today.
- Same threading model as today.

**Cons**:
- Full deserialize on launch (bounded by total entries, not raw bytes).
- ~8–15 MB binary plist for current dataset; loads in <500 ms.
- No queries — everything still computed in memory.

**Effort**: S (1–2 days).

**Fit verdict**: solves the cold-start problem. No query needs today justify SQLite. Pick this first; escalate only if it doesn't scale.

### Option B — append-only binary log per session

**Idea**: write parsed entries to `~/Library/Caches/ouroburn/entries.log` as a length-prefixed binary stream.
On launch: mmap + sequential read.

**Pros**:
- Sequential I/O, zero overhead per row.
- Trivial to truncate for force-refresh.

**Cons**:
- Append-only — old entries never compacted.
- No random access without secondary index.
- Build it ourselves; rare in Swift apps.

**Effort**: M (3–4 days).

**Fit verdict**: skip unless Option A profiles slow on the load step. Rolling our own format is rarely worth it.

### Option C — SQLite via GRDB.swift

**Idea**: durable relational store.
Tables: `usageEntry`, `fileMetadata`, `aggregateBucket`, `timelinePoint`.
Indexes on `(timestamp)`, `(projectPath, sessionId)`, dedup `UNIQUE(messageId, requestId)`.

**Pros**:
- Indexed queries (sub-second mode-switch aggregation).
- Dedup as `UNIQUE` constraint.
- Schema migrations via GRDB built-in.
- Survives schema upgrades cleanly.
- Path opens up future features (historical search, exports, DataDog-style charts).

**Cons**:
- New dependency (`groue/GRDB.swift` ~400 KB).
- Schema migrations to maintain.
- Concurrency model gets one more layer (GRDB pool + existing `OSAllocatedUnfairLock`).
- Risk of drift between in-memory aggregates and DB-stored aggregates.

**Effort**: M (6–8 days).

**Fit verdict**: only escalate here if Option A's plist hits a wall (e.g. > 100 MB or > 2 s load).

### Option D — Apple SwiftData / Core Data

**Pros**: native, no third-party dep.

**Cons**: heavyweight, opaque, iOS-leaning. Schema changes painful.

**Effort**: L (2+ weeks for full migration).

**Fit verdict**: skip. Wrong tool for a menu bar utility.

## Recommendation

**Ship Option A.**
Re-evaluate after one quarter of usage data.
If Option A's load step crosses 1 s consistently, jump straight to Option C.
Skip Option B entirely — it solves a problem we don't have.

## Option A — design

### File layout

```
~/Library/Caches/ouroburn/
  snapshot.json        # existing: aggregates only, render-on-launch
  file-cache.plist     # NEW: per-file mtime + parsed entries, hot path on relaunch
```

### Persisted shape

```swift
struct PersistedFileCache: Codable, Sendable {
    let schemaVersion: Int           // bump on UsageEntry shape changes
    let savedAt: Date
    let files: [PersistedFile]
}

struct PersistedFile: Codable, Sendable {
    let path: String                 // url.path
    let modifiedAt: Date
    let byteSize: UInt64             // also seeds tail-read offset
    let entries: [UsageEntry]        // already Codable
}
```

Binary plist (`PropertyListEncoder` with `.binary`).
~3× smaller than JSON, ~5× faster to decode.

### Lifecycle

| Event | Action |
|-------|--------|
| Launch | `bootstrapFileCache()` reads plist, populates in-memory `fileCache`. |
| Poll | Existing mtime check — only stale files re-parse. New writes go through unchanged. |
| Force refresh | `forceRefresh()` deletes plist, clears in-memory cache, re-polls. Same UX as today. |
| Schema bump | If `schemaVersion` mismatches, treat as miss → fall through to fresh parse. Self-healing. |
| Graceful quit | `applicationWillTerminate` → write plist on main thread (bounded duration). |
| Periodic save | Every Nth successful poll (e.g. every 10 polls = 10 min) write plist. Crash-resilient. |

### What this fixes

- Cold-start re-parse: 80 s → ~500 ms (decode plist) + incremental new files.
- Live tail-read seeds from `byteSize` field instead of re-stating files at popover open.
- Spinner state already age-driven (separate fix).

### What this doesn't change

- Aggregate computation (buckets, timelines) still in-memory.
- Mode switching still operates on the existing snapshot — no DB query.
- `DiskCache` stays as-is; `snapshot.json` continues to bootstrap UI.

### Concurrency

- Reads on main thread at launch only.
- Writes on existing background `queue` (qos: .utility).
- Atomic write via `Data.write(to:options: .atomic)`.
- No new locks. Existing `OSAllocatedUnfairLock<State>` continues to gate mutation.

### Failure modes

| Failure | Behavior |
|---------|----------|
| Plist corrupt | Decode throws → fall through to fresh parse. App still works, just slow. |
| Schema mismatch | Same as corrupt. |
| Disk full on save | Log error. Skip save. Next poll retries. |
| Concurrent writer crash mid-write | `.atomic` ensures partial file never persisted. |

### Migration plan

1. Add `PersistedFileCache` + `PersistedFile` Codable types alongside existing `CachedFile`.
2. Add `DiskCache.loadFileCache() -> PersistedFileCache?` + `saveFileCache(...)`.
3. In `BurnTracker.start()`: after pricing loaded, attempt `DiskCache.loadFileCache()`. If hit, populate `state.fileCache` directly with mtime + entries.
4. Add `wasCacheHit` flag on first poll log line for observability.
5. In `BurnTracker.stop()` and `applicationWillTerminate`: serialize current `state.fileCache` and save.
6. In `forceRefresh()`: also delete plist before clearing in-memory state.

### Test surface

- Round-trip Codable: encode + decode preserves all `UsageEntry` fields.
- Schema bump: write v1, attempt load with v2 reader → expect miss + log.
- Force refresh: plist deleted on disk after invocation.
- Crash during write: simulate by killing mid-encode → next launch decodes prior atomic file.

## Open questions

- Should `PersistedFile` store byteSize-at-time-of-parse so tail-read offsets persist across quits?
  Recommendation: **yes** — costs nothing, removes the popover-open reseed flicker.
- Should periodic saves piggyback on the 60 s poll or run on a separate cadence?
  Recommendation: every Nth poll — keeps it lazy and avoids racing the poll itself.
- Compression? `Data` zlib via `(NSData).compressed(using: .zlib)` cuts plist ~3× more.
  Defer until first profiling shows load > 500 ms.

## Decision log

- 2026-05-08 — chose Option A. Reason: smallest viable. No queries needed today. Easy to escalate to Option C later without rewriting the renderer.
