# Findings — Compact overlapping snapshots + partition by parameter to fix read scaling (#23)

## Issue context

## Problem

Each monthly snapshot re-pulls the full ~19-month realtime window (deliberately — it's how we catch ECCC's retroactive QC corrections to older provisional values), and we keep every full copy. Consecutive windows overlap ~18 months, so the canonical dataset is mostly duplicates that `query_canonical()` re-scans and de-duplicates on **every** read.

Measured today across 3 snapshots (local, network-free, to isolate structure from network noise):

| Measure | Current layout | Compacted + partitioned |
|---|---|---|
| Rows | 271,608,156 | 98,726,492 (**63.7% were duplicates**) |
| On-disk | 1.92 GB | 1.06 GB |
| Broad query (discharge span + count, all stations) | 2.42s | 0.11s (**~22×**) |
| Narrow query (1 station, 1 param, date range) | 0.12s | 0.23s (both fast — no win) |
| Bytes read for a water-temp query | 1.06 GB (all params mixed) | 55 MB (param=5 partition, **~20×**) |
| Bytes read for a daily-mean-discharge query | 1.06 GB | 11 MB (param=6, **~100×**) |

This is a **trajectory** problem, not a today-emergency: with only 3 snapshots the bloat is ~1.8×, but it grows linearly — at 24 monthly snapshots the canonical set is ~2B+ pre-dedup rows and every broad read drags the whole pile. Real-world reads are throughput-bound over S3 (~1.5 MB/s measured on a degraded link), so fewer bytes ≈ proportionally faster wall-clock.

## Proposal

- **Compaction step** after each snapshot: dedup to the latest `harvested_at` per `(STATION_NUMBER, Parameter, Date)` into a canonical store that readers point at. Keep the raw snapshots under a separate `raw/` prefix for provenance / QC-audit.
- **Partition the canonical store by `Parameter`** (and likely year). A single-parameter query then prunes to its partition — 55 MB vs 1.06 GB for water temp; ~100× for daily-mean discharge.
- **Simplify `query_canonical()`** to read the compacted store — no read-time dedup needed, so it's both faster and simpler.
- **zstd compression** on the compacted write to recover the size gap (rows dropped 63.7% but on-disk only 45%, because `write_dataset` re-encodes less tightly than the original chunks).
- **Cap Arrow's S3 retry/timeout** so a transient DNS blip fails in seconds, not the 8.7 min observed when the host briefly failed to resolve.

## What the benchmark showed (honest scope)

- Compaction helps **broad scans / full-history aggregates** (the queries that hang) — ~22× locally. It does **nothing** for narrow, already-prunable point queries (both sub-0.25s).
- **Partition-by-parameter is the cheap, big, independent lever** — 20–100× fewer bytes for single-parameter reads.
- Building the compacted copy cost ~72s for 271M rows locally — trivial, one-time per snapshot.
- Caveat: measurements are local to isolate layout from network; real-world adds the dominant, variable network cost.

## Non-goals

- Changing the pull cadence or the ~18-month overlap — both stay; that overlap is how we capture ECCC's QC revisions. This changes storage/read **layout** only.

## Related

- Dovetails with the proposed split of the general hydrometric archive (discharge + level) into its own repo/bucket, away from `water-temp-bc` — water temp is only ~4.5% of rows. Compaction + partitioning could land as part of that restructure or ahead of it.
- Reduces S3 egress per read (fewer bytes scanned), which matters for the account's data-transfer cost.


## Benchmark facts (2026-07-15/18, local, network-free)

- 3 snapshots (2026-05-14, 2026-06-01, 2026-07-01): 27 files, 1.92 GB, 271,608,156 rows pre-dedup
- Dedup to latest `harvested_at` per (STATION_NUMBER, Parameter, Date): **98,726,492 rows** (63.7% dupes) — this is the bootstrap golden number
- Partition sizes (arrow default codec): Parameter 5 = 55 MB, 6 = 11 MB, 46 = 561 MB, 47 = 481 MB
- Broad discharge aggregate: 2.42s current layout vs 0.11s compacted (~22×); narrow point queries: no win (both < 0.25s)
- Local compaction of 271M rows: 72s (arrow → duckdb → write_dataset). Runner budget ~10–15 min incl. S3 transfer.
- S3 throughput observed from this machine: ~1.5 MB/s sustained (degraded link day); reads are throughput-bound → bytes saved ≈ wall-clock saved
- Arrow S3 retry pathology: transient DNS failure produced an 8.7-min hang before erroring (curlCode 6); motivates explicit connect/request timeouts in query-helpers

## Verified assumptions (real July snapshot, 2026-07-18)

- Within-snapshot (STATION_NUMBER, Parameter, Date) uniqueness: **holds** (0 duplicate keys)
- NA-Date rows in July snapshot: **0** — NULL-key drop guard is insurance, not an active bug
- Within-snapshot `harvested_at` is constant per pull → tie cases only arise on re-merge; deterministic tiebreaker keeps output byte-reproducible

## Plan-agent design review (plan mode, 2026-07-18) — folded into approved plan

- **B1 (blocker):** naive "canonical + newest snapshot" merge permanently loses QC corrections from a failed month (aged-out window slice). Fix: watermark catch-up — merge canonical + ALL snapshot dirs ≥ watermark (inclusive); idempotent; bootstrap = degenerate case.
- **B2 (blocker):** disk (14 GB), not RAM, binds at 5-yr scale for a global merge (canonical in + out + sort spill). Fix: per-Parameter loop; worst partition ~50% of rows.
- **B3 (blocker):** duckdb parallel `COPY ... PARTITION_BY` does not preserve ORDER BY within partition files → silently forfeits row-group date-stats pruning. Fix: per-partition single COPY with explicit ORDER BY (falls out of B2). Test must assert stats stratify.
- **G1:** keep `to_duckdb()` bridge in `query_canonical()` — query.R Example 3 does grouped `slice_max(Date)`, unsupported by arrow's dplyr backend.
- **G2:** window ORDER BY needs stable tiebreaker beyond `harvested_at DESC` for reproducible output.
- **G3:** SQL window PARTITION BY treats NULLs as equal → NA-Date rows would silently collapse; drop explicitly + count + 0.1% fail threshold.
- **G4:** cast Parameter to INTEGER pre-write (else hive path `Parameter=5.0`); arrow reads int32; `filter(Parameter == 5)` prunes directories. Note: hive convention strips the Parameter column from the files themselves — browser-URL single-file fetches lose it (README caveat).
- **G5:** monthly full rewrite is correct (per-month deltas can't stay key-disjoint under QC corrections without reintroducing read-time dedup). But bucket versioning + monthly rewrite = stranded noncurrent versions forever → add NoncurrentVersionExpiration (~90d) scoped to `data/canonical/`.
- **G6:** accept the ~1–2 min monthly sync window over a version-pointer scheme (few readers; simplicity is the product). Document rewrite window in README. Pointer scheme = future option.
- **O2:** every `sync --delete` scoped to the exact partition dir — `stations_realtime.parquet`, `historic/`, `realtime/` all share the `data/` prefix.
- **A2:** arrow S3 timeouts require `S3FileSystem$create(connect_timeout=, request_timeout=)` + `$path()` — the plain `"s3://..."` URI form doesn't accept them; must also verify anonymous read still works for credential-less collaborators.

## Real-data hardening (Phase 4 bootstrap, 2026-07-18)

Three failures that ONLY real volume could expose (fixtures were green throughout):

1. **duckdb window dedup OOMs**: QUALIFY row_number() over the ~124M-row
   Parameter=46 input exhausted an 8 GB memory_limit. The window operator
   cannot spill enough. `preserve_insertion_order=false` + fewer threads did
   not save it.
2. **arg_max hash aggregate cannot spill either**: rewrote dedup as
   arg_max(row_struct, (harvested_at, coalesce(Value, -1e308))) GROUP BY key —
   still OOM'd at 4 GB with the spill dir at ~0 bytes even on a FILE-BACKED
   connection (in-memory connections don't offload at all; file-backed enables
   offload but struct-payload aggregate state is not externalized).
3. **Real schema broke the tiebreak sentinel**: production `Grade` is a
   double; fixtures had it as string, so `coalesce(s.Grade, '')` only failed
   on real data. Fixtures now mirror real types; tiebreaker simplified to
   (harvested_at, Value) — Grade/Approval links could never fire anyway since
   within-pull keys are verified unique.

**Final structure that works**: hash-shard each partition by STATION_NUMBER
into ceiling(input_rows / shard_rows=10e6) sub-passes; a key never crosses
shards so dedup stays exact; each shard writes its own internally-ordered
part-<k>.parquet. Memory scales as 1/K — bounded at any future store size.

**Decisive run at exact GHA profile (memory_limit=4GB, threads=2), local**:
159 s, rows_written = 98,726,492 (GOLDEN CHECK PASS — equals the measured
read-time-dedup count), compact_verify PASS, all 30 output files internally
ordered. Per-param: 5=4,474,827  6=155,261  46=49,697,562  47=44,398,842.

**Lifecycle rule**: put-bucket-lifecycle-configuration was blocked by the
permission classifier — needs user to run or allow. Merged config staged at
scratchpad/lifecycle-merged.json (existing IA-transition rule + new
canonical-noncurrent-expiry, 90d, prefix data/canonical/).
