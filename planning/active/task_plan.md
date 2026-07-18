# Task: Compact overlapping snapshots + partition by parameter to fix read scaling (#23)

Each monthly snapshot re-pulls the full ~19-month realtime window (deliberately — it's how we catch ECCC's retroactive QC corrections) and we keep every full copy. Consecutive windows overlap ~18 months, so the canonical dataset is mostly duplicates that `query_canonical()` re-scans and de-duplicates on every read: 271.6M rows across 3 snapshots, 63.7% duplicates, ~22× slower broad queries — and the tax grows linearly with every future snapshot. Fix: a monthly compaction step producing a deduplicated, Parameter-partitioned canonical store at `data/canonical/` that readers point at; raw snapshots stay at `data/realtime/` for provenance.

Design pressure-tested by Plan-agent review during plan mode (2026-07-18); blockers folded in: watermark catch-up (failed months self-heal), per-Parameter loop (bounds runner disk/RAM at any scale + guarantees ordered row-groups), deterministic dedup tiebreaker, NULL-key drop guard, int-cast hive paths, invariant gate before upload, golden-number bootstrap check (98,726,492 rows).

## Phase 1: Test fixtures first

- [ ] `scripts/compact-test.R` — fixture snapshots + assertions, plain Rscript, non-zero exit on failure. Matrix: QC-correction wins (newer harvested_at, different Value); aged-out date only in oldest snapshot survives; harvested_at tie → deterministic winner; NA Date dropped + counted; catch-up (canonical + 2 unmerged snapshots); re-merge idempotency (no-op); arrow read-back `filter(Parameter == N)` prunes + returns int32; row-group date-stats stratify (ordered write)

## Phase 2: `scripts/compact.R`

- [ ] Watermark catch-up merge: list S3 snapshot dirs, merge canonical + all dirs ≥ watermark (inclusive); bootstrap = no canonical → all raw; single code path; inputs downloaded from S3 (no httpfs dependency)
- [ ] Per-Parameter loop: filter, window dedup w/ tiebreaker, drop NULL Date/Parameter (log + 0.1% threshold), cast Parameter INTEGER, `COPY ... ORDER BY STATION_NUMBER, Date` zstd; `PRAGMA memory_limit` + `temp_directory` for the 7 GB runner
- [ ] Invariant gate before upload: key uniqueness, rowcount ≥ previous canonical, zero NULL dates, 4 partitions present, sane date range; refuse to sync on failure; summary output mirroring snapshot.R style
- [ ] compact-test.R green against the real compact functions

## Phase 3: Workflow integration

- [ ] `snapshot.yml`: compact + canonical-upload steps after raw upload; per-partition narrowly-scoped `aws s3 sync --delete`; timeout 150→180
- [ ] `workflow_dispatch` input `compact_only` to skip the pull (repair/bootstrap runs)

## Phase 4: Bootstrap + verify

- [ ] Bootstrap canonical over the 3 existing snapshots (compact-only dispatch or local run + sync)
- [ ] AC1: canonical rows == 98,726,492; spot-check broad-query timing vs old path from local machine
- [ ] One-time: `NoncurrentVersionExpiration` (~90d) lifecycle rule scoped to `data/canonical/`; record in findings.md

## Phase 5: Readers + docs

- [ ] `query-helpers.R`: default root → `data/canonical/`, drop slice_max dedup, keep `to_duckdb()` bridge; S3FileSystem with connect/request timeouts (fail in seconds, not the 8.7-min hang) + anonymous-read support for credential-less collaborators
- [ ] `scripts/query.R`: examples verified against new return type (esp. Example 3); note Parameter now int32/hive (column absent inside individual files)
- [ ] `README.Rmd`: layout tree (canonical + raw framing), dedup explanation now build-time, browser-URL caveat, documented monthly rewrite window, refresh `data/result.rds`; **full re-render** of README.md + index.html (no hand-patching)
- [ ] End-to-end: `query_canonical()` from local machine against S3 canonical — correct + fast

## Validation

- [ ] compact-test.R passes
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
