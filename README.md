water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

<a href="https://github.com/NewGraphEnvironment/water-temp-bc" title="View source on GitHub" style="float:right;display:inline-flex;align-items:center;gap:8px;background:#24292f;color:#ffffff;padding:8px 14px;border-radius:8px;text-decoration:none;font-weight:600;margin:0 0 10px 12px;"><svg height="22" width="22" viewBox="0 0 24 24" fill="#ffffff" aria-hidden="true"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.014 2.898-.014 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>Source
on GitHub</a>

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

<a href="https://github.com/NewGraphEnvironment/water-temp-bc" title="View source on GitHub"><img src="fig/cover.JPG" width="100%" alt="water-temp-bc" style="display: block; margin: auto;"/></a>

The goal of `water-temp-bc` is to document and serve out British
Columbia water temperature (and other realtime hydrometric) data. We
scrape the Environment Canada (ECCC) realtime feed for every BC station
once a month via [a GitHub Actions cron](.github/workflows/snapshot.yml)
and publish the result as a partitioned parquet dataset on S3.

<br>

## Data layout

    s3://water-temp-bc/data/
    ├── canonical/Parameter=<n>/part-*.parquet                         # THE dataset to query
    ├── canonical_meta.json                                            # compaction watermark
    ├── realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>/chunk_NNN.parquet   # raw monthly pulls (provenance)
    ├── historic/realtime_raw_*.parquet                                # frozen pre-modernization
    └── stations_realtime.parquet                                      # station metadata

**`canonical/` is the dataset to query.** Each monthly pull grabs the
full ~18-month realtime window ECCC serves and tags every row with a
`harvested_at` timestamp; a compaction step then merges it into
`canonical/`, keeping the most recent `harvested_at` per
`(STATION_NUMBER, Parameter, Date)` — that’s how QC corrections from
ECCC replace earlier provisional readings. The store is hive-partitioned
by `Parameter`, so a single-parameter query reads only its own slice,
and rows are ordered by `(STATION_NUMBER, Date)` so station/date filters
skip most row groups.

The raw overlapping pulls stay under `realtime/` for provenance — ~2/3
of their rows are duplicates by design, so query them only if you need
pre-correction history. `historic/` preserves the pre-modernization
parquets as-is; their schemas are heterogeneous, so read them one file
at a time with awareness of their shape.

The bucket lives in `us-west-2`. To pull a raw file in a browser, the
URL needs the explicit region:

    https://water-temp-bc.s3.us-west-2.amazonaws.com/data/realtime/2026/06/snapshot_2026-06-01/chunk_001.parquet

Two operational notes: individual files under `canonical/` do **not**
contain a `Parameter` column — per hive convention it lives in the
directory name, and `arrow::open_dataset()` / `query_canonical()`
reconstruct it (a single file fetched by URL won’t have it). And
`canonical/` is rewritten in place by the monthly run (~12:00–14:00 UTC
on the 1st); a query during that brief window can see a partition
mid-flip. Bucket versioning makes every rewrite recoverable.

<br>

## How to query

`scripts/query.R` has top-to-bottom worked examples (water temp for one
station, daily means across stations, latest reading per station,
reading a historic file). The short version:

``` r
source("scripts/query-helpers.R")

# Water temperature for one station, last 6 months
query_canonical(parameter = 5, stations = "07EA004", from = Sys.Date()-180) |>
  dplyr::collect()
```

`query_canonical()` returns a lazy dplyr query against the `canonical/`
store on S3. The store is already deduplicated at build time, so there
is no read-time dedup cost — a `parameter` filter prunes whole
partitions and station/date filters skip row groups. Chain more dplyr
verbs and call `dplyr::collect()` when you want the data in memory.

<br>

## Parameters

The archive carries *every* parameter ECCC serves for a station. Despite
the repo name, water temperature is a small slice — water level and
discharge dominate. This is the complete set (canonical-store counts,
2026-07-18; the partition column reads back as an integer):

| `Parameter` | Name                               | Unit | Rows       | Stations |
|-------------|------------------------------------|------|------------|----------|
| `5`         | Water temperature                  | °C   | 4,474,827  | 291      |
| `6`         | Discharge (daily mean)             | m³/s | 155,261    | 252      |
| `46`        | Water level (primary sensor)       | m    | 49,697,562 | 288      |
| `47`        | Discharge (primary sensor derived) | m³/s | 44,398,842 | 255      |

`6` is a daily-mean series — one value per day. `5`, `46` and `47` are
high-frequency sensor readings. **For realtime discharge use `47`, not
`6`.**

<br>

Please see <http://www.newgraphenvironment.com/water-temp-bc> for the
published table of station details and a sample query.

``` r
# Station metadata (location, drainage, timezone, etc.) — unchanged file path,
# managed separately from the realtime snapshots.
stations <- arrow::read_parquet("s3://water-temp-bc/data/stations_realtime.parquet")
```

``` r
# Per-station date ranges in the canonical dataset. Cached locally; refresh
# on demand with params$update_query (seconds against canonical/).
range <- query_canonical(parameter = 5) |>
  dplyr::group_by(STATION_NUMBER) |>
  dplyr::summarise(
    min_date = min(Date, na.rm = TRUE),
    max_date = max(Date, na.rm = TRUE),
    .groups  = "drop"
  ) |>
  dplyr::collect()

saveRDS(range, "data/result.rds")
```

<br>

### Sample query

The chunk below pulls the last 6 months of water-temperature
observations for one station via `query_canonical()`. It’s the same
pattern as Example 1 in `scripts/query.R`.

``` r
sample <- query_canonical(
  parameter = 5,
  stations  = "07EA004",
  from      = Sys.Date() - 180
) |>
  dplyr::select(STATION_NUMBER, Date, Value, Unit, Grade, Approval) |>
  dplyr::arrange(Date) |>
  dplyr::collect()
```
