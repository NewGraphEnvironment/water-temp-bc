water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

<a href="https://github.com/NewGraphEnvironment/water-temp-bc" title="View source on GitHub" style="float:right;display:inline-flex;align-items:center;gap:8px;background:#24292f;color:#ffffff;padding:8px 14px;border-radius:8px;text-decoration:none;font-weight:600;margin:0 0 10px 12px;"><svg height="22" width="22" viewBox="0 0 24 24" fill="#ffffff" aria-hidden="true"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.014 2.898-.014 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>Source
on GitHub</a>

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

<a href="https://github.com/NewGraphEnvironment/water-temp-bc" title="View source on GitHub"><img src="fig/cover.JPG" width="100%" alt="water-temp-bc" style="display: block; margin: auto;"/></a>

Water temperature, discharge, and water level for ~290 BC hydrometric
stations, queryable straight from S3 — no database, nothing to download
up front. A [monthly GitHub Actions
cron](.github/workflows/snapshot.yml) re-pulls the full ~18-month window
Environment Canada (ECCC) serves and compacts it into one deduplicated
parquet dataset, so QC corrections automatically replace earlier
provisional readings and the record keeps growing month over month.

<br>

## Quick start

``` r
install.packages(c("arrow", "dplyr", "duckdb", "dbplyr", "lubridate"))

source("https://raw.githubusercontent.com/NewGraphEnvironment/water-temp-bc/main/scripts/query-helpers.R")

# water temperature, one station, last 6 months
query_canonical(parameter = 5, stations = "07EA004", from = Sys.Date() - 180) |>
  dplyr::collect()
```

`query_canonical()` returns a lazy dplyr query — filter by `parameter`,
`stations`, `from`/`to`, chain any dplyr verbs, and `collect()` when you
want the data in memory. Typical queries return in a few seconds.
[`scripts/query.R`](scripts/query.R) has more worked examples (daily
means across stations, latest reading per station).

You currently need AWS credentials configured (any account, free tier is
fine) — fully anonymous access is planned.

<br>

## What’s in it

| `Parameter` | Name                               | Unit | Rows       | Stations |
|-------------|------------------------------------|------|------------|----------|
| `5`         | Water temperature                  | °C   | 4,474,827  | 291      |
| `6`         | Discharge (daily mean)             | m³/s | 155,261    | 252      |
| `46`        | Water level (primary sensor)       | m    | 49,697,562 | 288      |
| `47`        | Discharge (primary sensor derived) | m³/s | 44,398,842 | 255      |

**For realtime discharge use `47`, not `6`** — `6` is one value per day;
`5`, `46` and `47` are high-frequency sensor readings. Record starts
2024-10 and grows monthly. Station locations and metadata live in
`stations_realtime.parquet` (table below).

<br>

## Data layout

    s3://water-temp-bc/data/
    ├── canonical/Parameter=<n>/part-*.parquet     # THE dataset — query this
    ├── realtime/<yyyy>/<mm>/snapshot_.../         # raw monthly pulls (provenance only)
    ├── historic/realtime_raw_*.parquet            # frozen pre-2026 archive, odd schemas
    └── stations_realtime.parquet                  # station metadata

- `canonical/` is deduplicated at build time — newest QC’d value per
  station, parameter, and timestamp. `query_canonical()` and
  `arrow::open_dataset()` both read it directly.
- `realtime/` keeps every raw overlapping pull; ~2/3 duplicate rows by
  design. Only useful if you need pre-correction history.
- Single files fetched by URL need the region, e.g.
  `https://water-temp-bc.s3.us-west-2.amazonaws.com/data/realtime/2026/06/snapshot_2026-06-01/chunk_001.parquet`
  (note: files under `canonical/` carry `Parameter` in the directory
  name, not as a column). The store is rewritten ~12:00–14:00 UTC on the
  1st of each month.

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
