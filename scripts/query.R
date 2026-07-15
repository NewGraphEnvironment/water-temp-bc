# scripts/query.R
#
# Top-to-bottom worked examples for querying the water-temp-bc dataset.
# Read it once, then copy whichever block you need into your analysis.
#
# Dataset layout on S3 (region us-west-2):
#
#   s3://water-temp-bc/data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>/chunk_NNN.parquet
#     -- canonical going-forward source; appended monthly by
#        .github/workflows/snapshot.yml (Phase 4 of #17). Each snapshot is a
#        DIRECTORY of chunked parquet files, not a single file — the pull is
#        chunked to keep memory bounded on the runner. Readers don't care:
#        arrow::open_dataset() walks the whole tree.
#
#   s3://water-temp-bc/data/historic/realtime_raw_*.parquet
#     -- frozen pre-modernization archive. Heterogeneous schemas — read
#        individual files only, with awareness of their columns/types. See
#        the open follow-up issue for normalization plans.
#
# Parameters — the complete set (counts from the 2026-06-01 snapshot):
#   5  = Water temperature                  (°C,   4,108,352 rows, 291 stations)
#   6  = Discharge (daily mean)             (m3/s,   142,618 rows, 252 stations)
#   46 = Water level (primary sensor)       (m,   45,507,879 rows, 288 stations)
#   47 = Discharge (primary sensor derived) (m3/s, 40,716,328 rows, 255 stations)
#
# 6 is a daily-mean series (one value per day); 5, 46 and 47 are high-frequency
# sensor readings. For REALTIME DISCHARGE use 47, not 6.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
})

source("scripts/query-helpers.R")  # defines query_canonical()

# ----------------------------------------------------------------------------
# Example 1 — Water temperature for one station, last 6 months
# ----------------------------------------------------------------------------
# query_canonical() returns a lazy query so you can chain dplyr verbs before
# calling collect(). It already applies the (STATION_NUMBER, Parameter, Date)
# dedup against the most recent harvested_at, so you don't have to.

tw_single <- query_canonical(
  parameter = 5,
  stations  = "07EA004",
  from      = Sys.Date() - 180
) |>
  dplyr::select(STATION_NUMBER, Date, Value, Unit, Grade, Approval) |>
  dplyr::arrange(Date) |>
  dplyr::collect()

# ----------------------------------------------------------------------------
# Example 2 — Daily-mean water temp across multiple stations, last 12 months
# ----------------------------------------------------------------------------

tw_daily <- query_canonical(
  parameter = 5,
  stations  = c("07EA004", "08HA001", "08MF005"),
  from      = Sys.Date() - 365
) |>
  dplyr::mutate(date_day = as.Date(Date)) |>
  dplyr::group_by(STATION_NUMBER, date_day) |>
  dplyr::summarise(
    mean_C = mean(Value, na.rm = TRUE),
    n_obs  = n(),
    .groups = "drop"
  ) |>
  dplyr::collect()

# ----------------------------------------------------------------------------
# Example 3 — All BC stations: latest reading per station
# ----------------------------------------------------------------------------

latest_per_station <- query_canonical(parameter = 5) |>
  dplyr::group_by(STATION_NUMBER) |>
  dplyr::slice_max(Date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::select(STATION_NUMBER, Date, Value, Unit) |>
  dplyr::collect()

# ----------------------------------------------------------------------------
# Example 4 — Reading from a single historic file directly
# ----------------------------------------------------------------------------
# Historic files predate the modernization and have heterogeneous schemas
# (some have Parameter as string, some as double; Date types vary, etc.).
# Read one file at a time and cast explicitly:

historic_one <- arrow::read_parquet(
  "s3://water-temp-bc/data/historic/realtime_raw_20250521.parquet"
) |>
  dplyr::filter(as.numeric(Parameter) == 5) |>
  dplyr::mutate(Value = as.numeric(Value))
