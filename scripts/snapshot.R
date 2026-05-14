#!/usr/bin/env Rscript
# scripts/snapshot.R
#
# Pull ~18 months of BC realtime water-temp (and associated parameters) from
# the ECCC realtime service via tidyhydat / ngr::ngr_hyd_realtime and write a
# single point-in-time snapshot parquet to:
#
#   data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>.parquet
#
# A `harvested_at` column is added to every row so the read-time dedup pattern
# (slice_max(harvested_at) by STATION_NUMBER + Parameter + Date) can let newer
# QC'd values win over earlier provisional ones.
#
# Designed to run unattended in .github/workflows/snapshot.yml on the 1st of
# each month, and identically when run locally.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(arrow)
  library(fs)
  library(tidyhydat)
})

now   <- Sys.time()
today <- Sys.Date()

# --- Stations ----------------------------------------------------------------
stations_tidyhydat <- tidyhydat::realtime_stations(prov_terr_state_loc = "BC") |>
  dplyr::pull(STATION_NUMBER)

eccc_xlsx <- "data/eccc/BC_Stations_withTW.xlsx"
stations_eccc <- if (fs::file_exists(eccc_xlsx)) {
  readxl::read_excel(eccc_xlsx) |> dplyr::pull(stationid)
} else {
  warning("ECCC reference list not found at ", eccc_xlsx, " — proceeding with tidyhydat-only stations")
  character(0)
}

stations <- unique(c(stations_tidyhydat, stations_eccc))
message("Pulling realtime data for ", length(stations), " stations...")

# --- Pull --------------------------------------------------------------------
# Pin days_back so the snapshot window doesn't drift if ngr changes its default.
# 581 = current ngr default and the practical max ECCC realtime serves (~19mo).
DAYS_BACK <- 581

# Wrap with possibly() so a single station erroring (network blip, station
# temporarily missing, API change) does not abort the whole monthly snapshot —
# it just contributes NULL like a station with no realtime feed.
pull_station <- purrr::possibly(
  function(id) ngr::ngr_hyd_realtime(id, days_back = DAYS_BACK),
  otherwise = NULL
)

dat <- stations |>
  purrr::map(pull_station) |>
  purrr::discard(is.null) |>
  dplyr::bind_rows() |>
  ngr::ngr_tidy_cols_rm_na() |>
  dplyr::mutate(harvested_at = now)

if (nrow(dat) == 0) {
  stop("Snapshot produced 0 rows — refusing to write an empty parquet. ",
       "Investigate before the next monthly run.")
}
stopifnot("Date column missing from pulled data" = "Date" %in% names(dat))

# --- Write -------------------------------------------------------------------
yr  <- format(today, "%Y")
mo  <- format(today, "%m")
out_dir  <- fs::path("data", "realtime", yr, mo)
out_file <- fs::path(out_dir, paste0("snapshot_", today, ".parquet"))
fs::dir_create(out_dir, recurse = TRUE)

arrow::write_parquet(dat, out_file)

# --- Summary -----------------------------------------------------------------
date_min <- suppressWarnings(min(dat$Date, na.rm = TRUE))
date_max <- suppressWarnings(max(dat$Date, na.rm = TRUE))
message(
  "Wrote ", out_file, "\n",
  "  rows:              ", format(nrow(dat), big.mark = ","), "\n",
  "  distinct stations: ", dplyr::n_distinct(dat$STATION_NUMBER), "\n",
  "  date range:        ", format(date_min), " -> ", format(date_max), "\n",
  "  harvested_at:      ", format(now)
)
