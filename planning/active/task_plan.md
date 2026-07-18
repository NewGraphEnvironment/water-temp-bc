# Task: Compact overlapping snapshots + partition by parameter to fix read scaling (#23)

Each monthly snapshot re-pulls the full ~19-month realtime window (deliberately — it's how we catch ECCC's retroactive QC corrections) and we keep every full copy. Consecutive windows overlap ~18 months, so the canonical dataset is mostly duplicates that `query_canonical()` re-scans and de-duplicates on every read: 271.6M rows across 3 snapshots, 63.7% duplicates, ~22× slower broad queries — and the tax grows linearly with every future snapshot. Fix: a monthly compaction step producing a deduplicated, Parameter-partitioned canonical store at `data/canonical/` that readers point at; raw snapshots stay at `data/realtime/` for provenance.

Design pressure-tested by Plan-agent review during plan mode (2026-07-18); blockers folded in: watermark catch-up (failed months self-heal), per-Parameter loop (bounds runner disk/RAM at any scale + guarantees ordered row-groups), deterministic dedup tiebreaker, NULL-key drop guard, int-cast hive paths, invariant gate before upload, golden-number bootstrap check (98,726,492 rows).

## Phase 1: Test fixtures first

- [x] `scripts/compact-test.R` — fixture snapshots + assertions, plain Rscript, non-zero exit on failure. Matrix: QC-correction wins (newer harvested_at, different Value); aged-out date only in oldest snapshot survives; harvested_at tie → deterministic winner; NA Date dropped + counted; catch-up (canonical + 2 unmerged snapshots); re-merge idempotency (no-op); arrow read-back `filter(Parameter == N)` prunes + returns int32; row-group date-stats stratify (ordered write). Red by design until Phase 2 lands `compact-functions.R`.

## Phase 2: `scripts/compact.R`

- [x] Watermark catch-up merge: list S3 snapshot dirs, merge canonical + all dirs ≥ watermark (inclusive); bootstrap = no canonical → all raw; single code path; inputs downloaded from S3 (no httpfs dependency). Watermark = `data/canonical_meta.json`, uploaded only after all partitions publish (commit marker → failed runs self-heal).
- [x] Per-Parameter loop: filter, window dedup w/ tiebreaker, drop NULL Date/Parameter (log + 0.1% threshold), cast Parameter INTEGER, `COPY ... ORDER BY STATION_NUMBER, Date` zstd; `SET memory_limit` + `temp_directory` for the 7 GB runner. Split as `compact-functions.R` (testable core, `params` arg for one-partition-per-pass) + `compact.R` (S3 orchestrator; params = raw ∪ existing canonical partitions so an absent param is preserved).
- [x] Invariant gate before upload: key uniqueness, rowcount ≥ previous canonical (per-partition, from meta), zero NULL dates, partitions present, sane date range; refuse to sync on failure; summary output mirroring snapshot.R style
- [x] compact-test.R green against the real compact functions (27/27; duckdb clamps ROW_GROUP_SIZE to ~2048 floor — T8 fixture sized above it)

## Phase 3: Workflow integration

- [x] `snapshot.yml`: "Compact canonical store" step after raw upload (per-partition scoped sync lives inside compact.R); timeout 150→180
- [x] `workflow_dispatch` input `compact_only` (boolean) gates Pull + Upload steps off for repair/bootstrap runs; schedule runs unaffected (`inputs.compact_only != true` is true when inputs is empty)

## Phase 4: Bootstrap + verify

- [x] Bootstrap canonical over the 3 existing snapshots — local sharded merge at exact GHA profile (4GB/2 threads, 159s), synced to `s3://water-temp-bc/data/canonical/` (30 objects, **0.37 GB** — zstd 5× smaller than raw) + `canonical_meta.json` watermark `snapshot_2026-07-01`. Post-merge `compact_only` dispatch will verify the production "up to date" path.
- [x] AC1: canonical rows == 98,726,492 (golden PASS local); live-S3 spot-check: param-47 count matches exactly, broad aggregate 6.6s over network incl. discovery (previously minutes-to-hang)
- [x] `NoncurrentVersionExpiration` lifecycle — **redirected to rtj**: bucket lifecycle is owned by rtj `modules/s3/main.tf:141` (`aws_s3_bucket_lifecycle_configuration`); a CLI put would be clobbered on next `tofu apply`. Needs a module variable + rule in rtj (issue to file, pending user go). Staged JSON + analysis in findings.md.

## Phase 5: Readers + docs

- [x] `query-helpers.R`: default root → `data/canonical/`, dropped slice_max dedup, kept `to_duckdb()` bridge; S3FileSystem with connect/request 10s/60s timeouts. **Anonymous-read finding**: bucket policy grants only `s3:GetObject` — anonymous `open_dataset()` (needs ListBucket) never worked and still needs the rtj s3-module policy fix; helper uses the default credential chain meanwhile.
- [x] `scripts/query.R`: layout header rewritten (canonical primary, raw provenance, hive int/absent-column caveat); counts updated to canonical-store totals; Example 3 (grouped slice_max) verified live
- [x] `README.Rmd`: canonical-first layout tree + meta, build-time dedup story, hive + rewrite-window caveats, param table updated, `data/result.rds` refreshed (294 stations, 3.9s); full re-render of README.md + index.html, content-verified
- [x] End-to-end against live S3 canonical: Ex1 3,920 rows 1.8s; Ex3 latest-per-station 294 stations 1.3s (was minutes); Ex2 discharge window 1.1s; Parameter returns int

## Validation

- [ ] compact-test.R passes
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
