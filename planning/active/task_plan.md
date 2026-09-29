# Task: Normalize historic/ parquet schemas to enable unified arrow::open_dataset (#19)

During Phase 2 of #17 (legacy → `historic/` migration), discovered that the four pre-modernization parquet files have heterogeneous schemas — preventing `arrow::open_dataset(c(realtime, historic))` unified reads.

**Approach (plan gate, 2026-09-28):** fold the normalized historic archive into `canonical/` through the existing compaction, rather than rewriting the four files in place. Originals stay frozen as provenance.

## Phase 1: Contract tests (red first)
- [x] `scripts/historic-test.R`, in the `check()` style of `scripts/compact-test.R`. Local fixtures mirror each of the 4 real schemas, including string `Value`/`Parameter`/`Grade`, naked timestamps, missing columns and within-file duplicate keys
- [x] Assert that `historic_normalize()` output matches the raw-snapshot schema exactly (the 13 columns and types read from `realtime/2026/09`: `Date` as `timestamp[us, tz=UTC]`, `Grade` double, `Parameter` double, `harvested_at` `timestamp[us]`)
- [x] Assert that the Date wall-clock is unchanged after zone-stamping, that `RangeNumber`/`Quality`/`Interpolation` are dropped, and that `Symbol`/`Approval` pass through verbatim
- [x] Assert that NULL `Unit` is filled from the Parameter map (1 °C, 5 °C, 6 m3/s, 18 mm, 46 m, 47 m3/s; the map was verified against 20240119's Unit/Parameter crosstab)
- [x] Assert that `harvested_at` = the file's max `Date`, a lower bound on pull time that orders the files eccc < 20240119 < 20250521 < 20250728 < every snapshot
- [x] End-to-end: `compact_run()` over normalized fixtures plus a fixture canonical. Canonical wins on overlap, 20250728 beats 20250521, historic-only keys survive, and the output has no duplicate keys
- [x] Assert that `compact_verify()` accepts a 2002 minimum Date under the new floor

## Phase 2: Implement

Review-driven additions (review-plan.md, review-round1..4.md), all landed:
- [x] `exclude_matching`: 20250521's 52.0M stale copies of eccc/20240119 rows removed, keeping their metadata and resolving its 3.14M old+revised duplicate keys
- [x] Grade -1 → NULL; normalized files ORDER BY Parameter; date floor 2002-01-01
- [x] Shards sized by distinct keys and stations LPT-packed by load (`compact_pack_shards`, shard_keys 1.5e6)
- [x] `data/canonical.lock` + live-meta comparison guard every canonical upload in compact.R; the fold takes the lock after checking for live snapshot.yml runs
- [x] Bootstrap requires the 4-file `HISTORIC_FILES` manifest
- [x] `scripts/historic-functions.R`: `historic_normalize(in_file, out_file)`, a single duckdb `COPY (SELECT … TRY_CAST …)` projection that is S3-free, mirroring `compact-functions.R`
- [x] `compact-functions.R`: lower the `compact_verify()` `date_min_floor` default from 2020-01-01 to 2000-01-01, with a comment explaining why
- [x] `compact.R`: set `PARAMS_EXPECTED` to `c(1, 5, 6, 18, 46, 47)`, since air temp and precip arrive from 20240119. **On bootstrap only (no meta), include `data/historic/normalized/` as an input**, so a from-scratch rebuild can't silently drop the pre-2024-10 record
- [x] Run `historic-test.R`, `compact-test.R` and `snapshot-test.R` until all are green

## Phase 3: Fold into production canonical (one-time)
- [x] `scripts/historic-fold.R` orchestrator, reusing the `aws()` wrapper pattern and the per-partition loop from `compact.R`. It downloads the 4 originals, normalizes them to `WORK/historic_normalized/`, and uploads that to `s3://…/data/historic/normalized/`. Then, per Parameter, it syncs the canonical partition, runs `compact_run(normalized, canonical_dir=…)`, then `compact_verify(prev_rows = meta rows)`, then syncs back with `--delete` scoped to that partition. Last, it rewrites the meta: `last_merged` is unchanged, and a new `historic_merged` field lists the 4 files and a timestamp
- [x] (dry run done 2026-09-29, see findings; **publish is post-merge**) Dry run to a local output first. Record per-parameter rows in/out and min Date in findings, then publish. The run must finish well clear of the 1st-of-month cron window. Bucket versioning (#9) makes the rewrite reversible
- [ ] Verify against S3 anonymously: `query_canonical(parameter = 6, stations = "08EE003")` spans 2016 → 2026-09 with no duplicate keys, and `open_dataset("…/canonical/")` unifies with no errors

## Phase 4: Docs
- [x] (README.md rendered; **index.html re-render with `update_query = TRUE` is post-publish**, since `data/result.rds` must be rebuilt from the folded store) `README.Rmd`: update the "What's in it" counts and per-parameter start dates, change the layout block so `historic/` reads as originals plus `normalized/`, and add a "Record before 2024-10" subsection covering the Approval `1/2/4` codes, the Symbol vocabulary and missing B/E flags, the historic `harvested_at` meaning, and 20250521's NULL metadata. Then render `README.md` and `index.html`
- [x] `scripts/query.R`: update the header layout and param counts, and replace Example 4 (historic single-file read) with a pre-2024 `query_canonical()` example
- [x] Update the `query-helpers.R` header comment and the `CLAUDE.md` "Known state" bullets, which still describe dated files as the TODO
- [x] Write `research/historic-archive.md` with the schemas, the tz proof, the overlap and revision measurements and the Symbol vocabulary, and add a row to `research/README.md`

Also: `snapshot.yml` runtime comment; `CLAUDE.md` layout/known-state; `scripts/functions.R` top-level debug read guarded with `if (FALSE)` (it read a machine-local CSV at source time, which broke the render on any machine without it).

## Phase 5: Issue bodies
- [ ] Edit the #19 body: rewrite "Done when" for the fold-in, correct the Symbol/B-flag claim, and link the research file
- [ ] Post a pointer comment on wet#25: B/E flags exist nowhere, only ECCC `ICE` covers 2015-12→2022-12, and the pre-2024-10 record is now served by `query_canonical()`

## Validation

- [ ] Tests pass (`historic-test.R`, `compact-test.R`, `snapshot-test.R`)
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
