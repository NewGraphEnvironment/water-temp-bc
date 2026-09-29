# Findings — Normalize historic/ parquet schemas (#19)

## Plan-mode measurements (2026-09-28)

Produced by ad-hoc duckdb/httpfs scans of `s3://water-temp-bc/data/historic/*.parquet` and `canonical/` (anonymous, us-west-2).


| file | rows | span | notes |
|---|---|---|---|
| `eccc_20221213` | 10.0M | p5 2002-04→2022-12, p6 2015-12→2022-12 | `Value`/`Parameter` are strings, but every value parses, so the cast is safe. No `Unit`/`Grade`. `Approval` codes are `1/2/4`. `Symbol` uses ECCC codes (`ICE`, `ES`, `PX`, `E`…) on p6 only |
| `20240119` | 42.6M | 2022-06→2024-01, params 1,5,6,18,46,47 | `Grade` strings are `-1/10/20/30`. `Approval` values are `Provisional/Final`. No `Symbol`, `Qualifier` or `Qualifiers` |
| `20250521` | 134.0M | 2002→2025-05 | Superset amalgamation, so it holds eccc + 20240119 + newer rows. **`Unit`, `Grade` and `Qualifier` are NULL everywhere. `Approval` is NULL on 124M rows.** It has 3% duplicate keys within the file |
| `20250728` | 89.0M | 2023-12→2025-07 | `Grade` is double. `Symbol` is all NULL |

- The naked `timestamp[us]` values are **already UTC wall-clock**. I checked by joining 20250728 to canonical with no shift: p6 daily keys at 08:00 match only unshifted, and p5 matched 19,569 keys with 0 value diffs. So the fix is to stamp the zone, not to shift.
- When overlapping files disagree on Value (7–10% of p46/p47 rows), the later file holds real revisions. That supports picking the latest harvest, which is the same rule canonical uses.
- **Nothing carries ice `B` / estimate `E` flags.** Canonical p6 `Symbol` is 100% NULL, and so is historic 20250728. Only the ECCC dump carries flags, in ECCC's own vocabulary (807 `ICE` rows plus `ES`, `E` and others), for 2015-12 → 2022-12. This contradicts the 2026-09-28 edit to #19 and changes what wet#25 can report. `Symbol` is still kept.


### Per-file profile detail

- Parameter spans (min/max Date, stations):
  - eccc: p5 9,696,029 rows 2002-04-30→2022-12-13 (139 stn); p6 307,724 rows 2015-12-31→2022-12-16 (132 stn). Value NULL on 6,000 rows; 0 unparseable Value/Parameter strings.
  - 20240119: p1 463,749 (15 stn); p5 1,801,464 (129); p6 582 (1); p18 301,487 (9); p46 20,659,339 (129); p47 19,365,145 (119). All 2022-06-17→2024-01-19.
  - 20250521: p1/p18 identical to 20240119; p5 13,814,927 2002→2025-05-21 (295); p6 444,920 2015-12-31→2025-05-21 (254); p46 62,041,869; p47 56,982,748 (from 2022-06-17).
  - 20250728: p5 3,353,915; p6 141,797; p46 45,271,360; p47 40,196,663; all 2023-12-24→2025-07-28.
- Unit ↔ Parameter crosstab (20240119): m=46; m3/s=47+6; °C=5+1 (2,265,213 = 1,801,464 + 463,749); mm=18.
- Canonical (2026-09-13 meta): 110,823,511 rows; min Date 2024-10-10; harvested_at 2026-05-14 → 2026-09-13; Approval `Provisional/Provisoire` | `Final/Finales`; p6 Symbol 100% NULL; p6 Dates at 08:00 (167,462) / 07:00 (6,215) UTC.
- tz proof: 20250728 ⋈ canonical on 3 stations (08EE003, 08EE013, 07EA004), Date unshifted: p6 865 keys, p5 19,569 keys (0 value diffs). With +8h shift p6 matches 0 — daily 08:00 keys only align unshifted.
- Revisions: 20240119 vs 20250521 value diffs p46 25,620/333,542, p47 39,150/372,639, p5 0. 20250521 vs 20250728 p46 74,388/420,068, p6 200/1,543.
- Within-file duplicate keys (3 stations): eccc 200,442 vs 200,363 distinct; 20250521 1,942,649 vs 1,877,879; others none.

## Issue context

During Phase 2 of #17 (legacy → `historic/` migration), discovered that the four pre-modernization parquet files have heterogeneous schemas — preventing `arrow::open_dataset(c(realtime, historic))` unified reads.

## Schemas observed (`s3://water-temp-bc/data/historic/`)

| File | Notable schema differences vs. new `realtime/` snapshots |
| --- | --- |
| `realtime_raw_eccc_20221213.parquet` | `Parameter: string`, `Value: string`, has `RangeNumber`/`Quality`/`Interpolation`/`Symbol`; missing `Unit`, `Grade`, `Qualifier`, `harvested_at` |
| `realtime_raw_20240119.parquet` | `Grade: string` (vs. `double` in new); missing `harvested_at`; missing `Date` tz |
| `realtime_raw_20250521.parquet` | Has `RangeNumber`/`Quality`/`Interpolation`/`Symbol`/`Qualifier`/`Qualifiers: bool`; `Grade: string`; missing `Date` tz |
| `realtime_raw_20250728.parquet` | Has `Symbol`/`Qualifiers: bool`; `Grade: double`; missing `Date` tz, `harvested_at` |
| `realtime/.../snapshot_<date>.parquet` (canonical) | `Date: timestamp[us, tz=UTC]`, `Grade: double`, has `harvested_at`; no `RangeNumber`/`Quality`/`Interpolation`/`Symbol`/`Qualifiers` |

The blocker is the `Date` tz mismatch (`tz=UTC` vs. naked `timestamp[us]`) and the `Grade` type mismatch (`string` vs. `double`). arrow refuses to merge these in a single unified dataset.

## Impact

For now, Phase 2 of #17 scoped the canonical source to `realtime/` only. The `query_canonical()` helper (Phase 3) reads from `realtime/`. Anyone wanting pre-2024-10 history must read historic files individually with awareness of their schemas. This is suboptimal but unblocks the monthly job and the read-side ergonomics.

## Proposed work

Pull each historic file down, project to the canonical schema (drop or coerce the divergent columns), write back to `historic/`. Pseudocode:

```r
canonical_cols <- c("STATION_NUMBER", "Date", "Name_En", "Value", "Unit",
                    "Grade", "Symbol", "Approval", "Parameter", "Code",
                    "Qualifier", "Qualifiers", "harvested_at")

for (f in historic_files) {
  d <- arrow::read_parquet(f) |>
    dplyr::mutate(
      Date         = lubridate::force_tz(Date, "UTC"),
      Grade        = as.numeric(Grade),
      Value        = as.numeric(Value),
      Parameter    = as.numeric(Parameter),
      harvested_at = NA_real_  # historic rows have unknown harvest time
    ) |>
    dplyr::select(dplyr::any_of(canonical_cols))
  arrow::write_parquet(d, f)
}
```

Notes:

- `harvested_at = NA` for historic rows means `slice_max(harvested_at)` ranks them below any new snapshot row at the same `(STATION_NUMBER, Parameter, Date)` — newer snapshots always win on collision, which is the correct semantics. (Verify arrow/duckdb sort NA-last; may need `coalesce(harvested_at, <sentinel-old-date>)`.)
- The `eccc_20221213.parquet` is the most divergent (string Value, string Parameter) — likely needs a separate first-pass coercion step to parse numerics before the projection.
- Bucket versioning is on (#9) — original schemas are recoverable if normalization mis-fires.

**Keep `Symbol` and `Qualifiers` (edited 2026-09-28).** The canonical store now carries both (checked on `Parameter=6`, 2026-09-28), so the table above is out of date on that row. `Symbol` carries the ice (`B`) and estimate (`E`) flags, and a projection that drops it makes ice-affected winter discharge indistinguishable from open-water values. NewGraphEnvironment/wet#25 reads the 2016–2024 daily discharge from `historic/` to bridge approved HYDAT to the present, and reports the share of ice-affected days per window.

## Done when

- [ ] All four historic files conform to the canonical schema (same column names, same types, including `Date` with UTC tz).
- [ ] `arrow::open_dataset(list(arrow::open_dataset("s3://.../realtime/"), arrow::open_dataset("s3://.../historic/")), unify_schemas = TRUE)` succeeds.
- [ ] `query_canonical()` accepts an `include_historic = TRUE` arg or similar to broaden the source to the unified dataset.
- [ ] README "How to query" section gains a "querying historic data" subsection.

## Related

- #17 — modernization parent (Phase 2 discovery)
- #5 — ECCC `mdb` ingestion (touches `eccc_20221213.parquet`'s upstream source; consider whether to re-derive it from the `mdb` rather than coerce the current parquet)
- NewGraphEnvironment/wet#25 — consumer: station daily discharge 2016 onward, needs `Symbol`


## Errors Encountered

| Error | Resolution |
|-------|------------|
| duckdb `SET TimeZone` / `AT TIME ZONE` needs the `icu` extension (not installed) | Compare via `CAST(tz_col AS TIMESTAMP)` instead |
