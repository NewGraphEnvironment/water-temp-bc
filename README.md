water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

<img src="fig/cover.JPG" alt="" width="100%" style="display: block; margin: auto;" />

The goal of `water-temp-bc` is to document and serve out British
Columbia water temperature (and other realtime hydrometric) data. We
scrape the Environment Canada (ECCC) realtime feed for every BC station
once a month via [a GitHub Actions cron](.github/workflows/snapshot.yml)
and publish the result as a partitioned parquet dataset on S3.

<br>

## Data layout

    s3://water-temp-bc/data/
    ├── realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>.parquet  # canonical, append-only
    ├── historic/realtime_raw_*.parquet                      # frozen pre-modernization
    └── stations_realtime.parquet                            # station metadata

The bucket lives in `us-west-2`. To pull a raw file in a browser, the
URL needs the explicit region:

    https://water-temp-bc.s3.us-west-2.amazonaws.com/data/realtime/2026/05/snapshot_2026-05-14.parquet

Each monthly snapshot pulls the full ~18-month realtime window (the most
ECCC serves) and tags every row with a `harvested_at` timestamp.
Consecutive snapshots overlap by design, and the canonical value at each
`(STATION_NUMBER, Parameter, Date)` is the row with the most recent
`harvested_at` — that’s how QC corrections from ECCC win over earlier
provisional readings. The dedup is handled at read time by
`query_canonical()` so callers don’t have to think about it.

The `historic/` prefix preserves the pre-modernization parquets as-is
for explicit archival reads. Their schemas are heterogeneous (different
column types, different column sets) — read them one at a time with
awareness of their shape.

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

`query_canonical()` returns a lazy dplyr query against the partitioned
`realtime/` tree on S3, automatically deduped on
`(STATION_NUMBER, Parameter, Date)` by taking the row with the latest
`harvested_at`. Chain more dplyr verbs and call `dplyr::collect()` when
you want the data in memory.

Common parameter codes: `5` = water temperature, `6` = discharge (daily
mean), `46` = water level.

<br>

Please see <http://www.newgraphenvironment.com/water-temp-bc> for the
published table of station details and a sample query.

``` r
# Station metadata (location, drainage, timezone, etc.) — unchanged file path,
# managed separately from the realtime snapshots.
stations <- arrow::read_parquet("s3://water-temp-bc/data/stations_realtime.parquet")
```

``` r
# Per-station date ranges in the canonical realtime/ dataset. Slow over the
# network so we cache the result locally and only refresh on demand.
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
