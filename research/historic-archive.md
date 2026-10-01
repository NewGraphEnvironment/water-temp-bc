# The pre-2024-10 historic archive

**Verified:** 2026-09-30 · **Issues:** #19 (fold into canonical), #17 (where the files came from), NewGraphEnvironment/wet#25 (consumer) · **Produced by:** duckdb/httpfs scans of `s3://water-temp-bc/data/historic/*.parquet` and `canonical/`, plus `scripts/historic-fold.R` and `scripts/historic-fold-check.R` (logs: `data-raw/logs/historic_fold/`)

Four parquet files from before the modernization live under `data/historic/`. They are frozen: #19 normalized copies of them (`data/historic/normalized/`) and merged those copies into `canonical/`, so `query_canonical()` now serves them. The originals are never rewritten.

## The four files

| file | rows | span | shape |
|---|---|---|---|
| `realtime_raw_eccc_20221213.parquet` | 10,003,753 | p5 2002-04-30 → 2022-12-13 (139 stations), p6 2015-12-31 → 2022-12-16 (132) | Bulk dump that ECCC forwarded (`scripts/extract-eccc.R`). `Value` and `Parameter` are strings, and every non-NULL one parses. There is no `Unit`/`Grade`, and it has `RangeNumber`/`Quality`/`Interpolation` |
| `realtime_raw_20240119.parquet` | 42,591,766 | 2022-06-17 → 2024-01-19; params 1, 5, 6, 18, 46, 47 | `Grade` is a string (`-1`, `10`, `20`, `30`). It has no `Symbol`, `Qualifier` or `Qualifiers` |
| `realtime_raw_20250521.parquet` | 134,049,700 | 2002 → 2025-05-21 | An amalgamation of eccc, 20240119 and newer pulls. `Unit`, `Grade` and `Qualifier` are NULL on every row, and `Approval` is NULL on the 124M rows that are not eccc. About 3% of its keys are duplicated within the file |
| `realtime_raw_20250728.parquet` | 88,963,735 | 2023-12-24 → 2025-07-28 | `Grade` is a double. `Symbol` is NULL on every row |

Parameters 1 (air temperature) and 18 (precipitation) appear only in the 2022-06 → 2024-01 pull, at 15 and 9 stations.

## Date is UTC wall clock

In every file `Date` is a naked `timestamp[us]`. The values are UTC. I checked this by joining 20250728 to canonical (`timestamp[us, tz=UTC]`) on three stations (08EE003, 08EE013, 07EA004):

- The p6 daily values carry an 08:00 stamp in both stores. They match 865 keys unshifted and none with an 8 h shift.
- p5 matched 19,569 keys unshifted, with 0 value differences.

Normalization therefore stamps the zone and does not shift the value. It builds the value from text with an explicit `+00`, because a plain `CAST(TIMESTAMP AS TIMESTAMPTZ)` in duckdb follows the session `TimeZone` whenever the `icu` extension is loaded.

## Overlap and revisions

The files overlap heavily, and where they overlap, the later pull holds revised values:

| pair (3 stations) | shared keys | Value differs |
|---|---|---|
| 20240119 → 20250521, p46 | 333,542 | 25,620 |
| 20240119 → 20250521, p47 | 372,639 | 39,150 |
| 20240119 → 20250521, p5 | 27,728 | 0 |
| 20250521 → 20250728, p46 | 420,068 | 74,388 |
| 20250521 → 20250728, p6 | 1,543 | 200 |
| 20250728 → canonical, p6 | 865 | 634 |

Each normalized file therefore gets `harvested_at` = the file's own maximum `Date`. That is a lower bound on when the file was pulled, and it orders them eccc < 20240119 < 20250521 < 20250728 < every monthly snapshot (the first snapshot is 2026-05-14). The compaction's rule, latest `harvested_at` per (station, parameter, Date), then keeps the newest value everywhere, and canonical wins every key it shares with the archive.

20250521 needed one more step. It is an amalgamation that re-carries eccc and 20240119 rows, deduplicated on (key, Value), so 52,022,652 of its 134,049,700 rows are copies of older rows with `Grade`/`Approval` stripped. Each of its 3,141,110 duplicate keys is one such copy plus a revision. `historic_normalize(exclude_matching =)` removes the copies, which leaves 82,027,048 rows and no duplicate key. Where the value did not change, the older row survives with its metadata.

One consequence: where 20250521 genuinely revised a value, its row wins in full, with NULL `Grade` and `Approval` (7,714,362 rows after the fold). The older metadata described a different value, so it did not apply anyway. `Grade` `-1`, which the 2022-2024 feed used for "no grade", becomes NULL, the value the feed has used since. `Unit` is the exception, because it follows from the parameter. It is filled from the code: 1 °C, 5 °C, 6 m³/s, 18 mm, 46 m, 47 m³/s. That mapping is one-to-one in 20240119.

## After the fold

Published 2026-09-30 (`data-raw/logs/historic_fold/20260930_publish.log`), with the same counts as the 2026-09-29 dry runs: canonical went from 110,823,511 to 212,198,908 rows. `scripts/historic-fold-check.R` passes on live S3, with snapshot-harvested rows exactly equal to the pre-fold counts. A `compact_only` runner pass (run 36753933165) took 8 min 11 s against the folded store and left every count unchanged. p5 starts 2002-04-30 (17.3M rows, 306 stations), p6 starts 2015-12-31 (571K, 264), p46/p47 start 2022-06-17 (101.8M / 91.8M), and p1/p18 (air temperature, precipitation) are frozen at 2022-06-17 → 2024-01-19. Rows written equal an independent distinct-key count over the inputs for every parameter.

## Vocabulary differs from the realtime feed

- **`Approval`**: rows from the ECCC dump carry the codes `1` (9.96M), `4` (41,057) and `2` (110). Their meanings were never documented alongside the dump, so the codes are passed through as-is. Realtime rows use `Provisional/Provisoire` and `Final/Finales`.
- **`Symbol`**: only the ECCC dump carries flags, all on p6 (2015-12-31 → 2022-12-16), in ECCC's own vocabulary: `ES` 938, `ICE` 807, `PX` 418, `SD;ES`/`ES;SD` 770, `PN` 277, `EQMAL` 262, `SD` 219, `HMN` 123, `E` 100, `DRY` 20, and others.
- **There are no HYDAT-style `B` (ice) or `E` (estimate) flags anywhere else.** Canonical p6 `Symbol` is 100% NULL (173,677 rows, 2026-09-13 store), and so are 20250728 and the non-eccc rows of 20250521. For the share of ice-affected days (wet#25), only the dump's `ICE` rows cover 2015-12 → 2022-12. After that there is nothing, and missing flags do not mean open water.
