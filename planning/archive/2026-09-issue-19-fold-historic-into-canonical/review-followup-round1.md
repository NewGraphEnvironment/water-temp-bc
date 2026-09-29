# Review: follow-up round 1 (historic-fold-check.R + WORK move)

Reviewer probes in `scratchpad/f1work/` (read-only against `fold/work/folded`, `fold/work/historic_normalized`, `fold/work/historic_raw`; anonymous S3 reads only).

## Findings

- **[Medium]** `scripts/historic-fold-check.R:110-119` (and the check set as a whole): nothing checks that the pre-fold canonical rows survived the publish, or that canonical won the overlapping keys. After publish, the S3 run can PASS on a store where historic rows replaced canonical rows or canonical-only keys were lost:
  - "rows per parameter == meta$rows" is circular. The fold writes `meta$rows` from the same run's `rows_written` (historic-fold.R:235, 265), so it only proves the upload matched the run, not that the run was right.
  - The fold's own `compact_verify(prev_rows =)` floor cannot see it either, because 12-46 M added historic rows swamp any loss (p5: 4,996,180 -> 17,292,881).
  - "every normalized historic key is in the store" checks key presence only, so it cannot tell which source won.
  - A self-contained assertion exists and holds exactly on the dry-run store. Per parameter, `count(*) FILTER (WHERE harvested_at >= TIMESTAMP '2026-05-14')` (canonical-sourced rows) is 1: 0, 5: 4,996,180, 6: 173,677, 18: 0, 46: 55,849,790, 47: 49,803,864. That equals the pre-fold S3 rows in `20260929_check_s3_prefold.log`.
  - The historic-sourced count (`< 2026-05-14`) equals that log's per-parameter `missing`: 12,296,701, 397,415, 45,913,611, 42,002,434, 463,749 and 301,487.
  - Publish overwrites both the meta's `rows` and `historic-fold-report.csv` in WORK, so the pre-fold counts must be pinned for the post-publish run. Two ways: from that log (valid while `completed_at` is still `2026-09-13T04:05:57Z`), or by having the fold write `rows_before` into `meta$historic_merged`.
  - Without one of these, the post-publish PASS does not cover "canonical wins / nothing canonical was lost". Today that property rests only on the dry run's arithmetic: missing == added.

- **[Low]** `scripts/historic-fold-check.R:92`: the p6 "one row per PST day" check uses `Date - 8h`, which puts 07:00 UTC and 08:00 UTC stamps of the same day on different "days". The store has both conventions:
  - 11 stations (08NB005, 08NG065, 08NK002, 10DA001, ...) stamp every row at 07:00 UTC year-round (MST midnight), while the rest use 08:00.
  - So if one source stamps a station-day at 07:00 and another stamps the same day at 08:00, the result is a real duplicate that this check PASSES. Demo: two rows for one station, `2020-07-01 07:00+00` and `2020-07-01 08:00+00`: the check's query returns 0, and grouping on the UTC date returns 1.
  - Measured today: every station uses a single convention across all four normalized files and canonical, and UTC-date grouping, -7h grouping and -8h grouping all give 0. So there is **no false pass on current data**, but the check is blind to the mixed-convention case it exists to catch.
  - Every p6 stamp is 07:00 or 08:00 UTC, so grouping on `CAST(CAST(Date AS TIMESTAMP) AS DATE)` catches this case and is 0 on the dry-run store.

- **[Low]** `scripts/historic-fold.R:72`: the new default `WORK = data/historic-fold` sits inside `data/`, which `scripts/sync-data.R` mirrors with `aws s3 sync data s3://water-temp-bc/data --delete`. A run of that script would upload about 3 GB of working files to `s3://water-temp-bc/data/historic-fold/`: the originals, the normalized files, a second hive `folded/Parameter=*` store, `canonical_meta.json`/`canonical_meta_now.json` copies and the `canonical.lock` body.
  - **Outside the diff, and worse:** with local `data/` holding only `eccc/` and `readme.md`, `sync-data.R`'s `--delete` would already remove `canonical/`, `realtime/`, `historic/` and `canonical_meta.json` from S3. CLAUDE.md still lists it as the sync step. This is pre-existing, but it is a one-command data-loss path next to a store that is about to become the only copy of the folded record.

## Checked and sound (no finding)

- **S3 normalized path:** with duckdb httpfs and credentials blanked (`SET s3_access_key_id=''` etc.), the anonymous reads all work on the public bucket:
  - `glob('s3://water-temp-bc/data/historic/*.parquet')` lists the 4 files (`*` does not descend into `normalized/`).
  - `parquet_schema()` over an S3 glob works.
  - `read_blob('s3://.../canonical_meta.json')` works.
  - A missing `normalized/` makes the query fail with "IO Error: No files found", so the script exits non-zero. It fails loud, not toward pass.
  - Note: duckdb does pick up the session's AWS credentials when present (`s3_access_key_id` is non-empty in Rscript), so the header's "S3 reads are anonymous" holds only for arrow. Expired credentials would make the duckdb side fail loudly (403), not pass.
- **Normalized vs originals:** every raw original key `(STATION_NUMBER, Parameter, Date)`, read with naive `Date` as UTC, is present in the normalized files (anti-join: 0 rows). So checking against the normalized files rather than the originals loses nothing on this data.
- **ICE:** the header's premise "the only source of Symbol flags" is loose. Normalized 20250521 carries 631 Symbol rows, 115 of them ICE, and all 115 are on eccc ICE keys; they win dedup with harvested_at 2025-05-21. The count equality still holds (807 = 807), and a lost flag would push it below the source count, so it fails in the right direction. Every p6 Symbol count in the store matches `research/historic-archive.md`.
- **Error paths:** `check()` uses `isTRUE()`, so NA reads as FAIL. There is no `tryCatch`, so any query error halts Rscript non-zero. `all(per$rows == per$keys)` cannot be vacuous, because an empty store glob errors before it.
- **Meta subset direction:** `unlist(meta$rows)[per$p]` would not notice a parameter that is in meta but missing from the store. Every parameter (1, 5, 6, 18, 46, 47) has historic keys, though, so the missing-key check catches a missing partition.
- **Timestamps:** `CAST(TIMESTAMPTZ AS TIMESTAMP)` is UTC here because ICU is not installed in the duckdb extension dir. If ICU were loaded, casts would go to the local zone and the "earliest Date" check would fail loudly on a Pacific machine. That fails in the loud direction, so it is not a pass-while-false.
- The fold's `compact_run()` clears `out_dir` before writing (compact-functions.R:142), so a persistent WORK does not leak stale shards from a crashed run into a publish.
