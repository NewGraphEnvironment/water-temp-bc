# scripts/query.R
#
# Top-to-bottom worked examples for querying the water-temp-bc dataset.
# Read it once, then copy whichever block you need into your analysis.
#
# Dataset layout on S3 (region us-west-2):
#
#   s3://water-temp-bc/data/canonical/Parameter=<n>/part-*.parquet
#     -- THE dataset to query: deduplicated at build time (latest
#        harvested_at wins per STATION_NUMBER + Parameter + Date, so ECCC QC
#        corrections replace provisional values), hive-partitioned by
#        Parameter so single-parameter queries read only their slice.
#        Rebuilt monthly by scripts/compact.R (#23); watermark in
#        data/canonical_meta.json. Note: per hive convention the Parameter
#        column lives in the directory name (int), not inside the files —
#        query_canonical()/open_dataset() reconstruct it; a single file
#        fetched by URL won't have it.
#
#   s3://water-temp-bc/data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>/chunk_NNN.parquet
#     -- raw overlapping monthly pulls, kept for provenance. Consecutive
#        snapshots re-pull the same ~18-month window, so ~2/3 of rows are
#        duplicates — query these only if you need pre-correction history.
#
#   s3://water-temp-bc/data/historic/realtime_raw_*.parquet
#     -- frozen originals of the pre-2024-10 archive (four overlapping pulls,
#        mismatched schemas). Normalized copies in historic/normalized/ were
#        merged into canonical/ (#19), so canonical already holds this record;
#        research/historic-archive.md describes the files.
#
# Parameters — the complete set (canonical-store counts after the #19 fold):
#   5  = Water temperature                  (°C,  from 2002-04, 17,292,881 rows, 306 stations)
#   6  = Discharge (daily mean)             (m3/s, from 2015-12,    571,092 rows, 264 stations)
#   46 = Water level (primary sensor)       (m,   from 2022-06, 101,763,401 rows, 299 stations)
#   47 = Discharge (primary sensor derived) (m3/s, from 2022-06, 91,806,298 rows, 262 stations)
#   1  = Air temperature                    (°C,  2022-06 -> 2024-01 only, 15 stations)
#   18 = Precipitation                      (mm,  2022-06 -> 2024-01 only,  9 stations)
#
# 6 is a daily-mean series (one value per day); 5, 46 and 47 are high-frequency
# sensor readings. For REALTIME DISCHARGE use 47, not 6. Rows before 2024-10
# use older vocabularies (Approval codes 1/2/4, ECCC Symbol codes such as ICE).

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
})

source("scripts/query-helpers.R")  # defines query_canonical()

# ----------------------------------------------------------------------------
# Example 1 — Water temperature for one station, last 6 months
# ----------------------------------------------------------------------------
# query_canonical() returns a lazy query so you can chain dplyr verbs before
# calling collect(). The store is already deduplicated at build time, so
# there is no read-time dedup cost — filters prune partitions and row groups.

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
# Example 4 — The long record: daily discharge from 2016
# ----------------------------------------------------------------------------
# canonical/ also holds the pre-2024-10 archive (#19), so the same helper
# reaches back to 2016 for daily discharge and 2002 for water temperature.
# Those older rows carry ECCC's Approval codes (1/2/4) and, for 2015-12 to
# 2022-12 daily discharge only, ECCC Symbol flags such as ICE.

q_long <- query_canonical(
  parameter = 6,
  stations  = "08EE003",
  from      = as.Date("2016-01-01")
) |>
  dplyr::select(STATION_NUMBER, Date, Value, Approval, Symbol) |>
  dplyr::arrange(Date) |>
  dplyr::collect()
