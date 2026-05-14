#!/usr/bin/env Rscript
# scripts/snapshot.R
#
# Pull ~18 months of BC realtime water-temp (and associated parameters) from
# the ECCC realtime service via tidyhydat / ngr::ngr_hyd_realtime and write a
# single point-in-time snapshot as a directory of chunked parquets at:
#
#   data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>/chunk_NNN.parquet
#
# A `harvested_at` column is added to every row so the read-time dedup pattern
# (slice_max(harvested_at) by STATION_NUMBER + Parameter + Date) lets newer
# QC'd values win over earlier provisional ones.
#
# Stations are pulled in chunks so peak R memory stays well under the 7 GB
# GHA runner ceiling. Each chunk is written + freed before the next starts.
# Readers don't care about chunking; arrow::open_dataset() walks the tree.

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

# --- Pull + write in chunks --------------------------------------------------
# 581 = current ngr default and the practical max ECCC realtime serves (~19mo).
# Pinned so the window doesn't drift if ngr changes its default.
DAYS_BACK  <- 581

# Chunk size keeps peak R memory bounded — accumulating all ~290 stations
# before bind_rows OOM-killed the 7 GB GHA runner in run 25880907973.
CHUNK_SIZE <- 50

# Wrap with possibly() so a single station erroring (network blip, station
# temporarily missing, API change) does not abort the whole monthly snapshot.
pull_station <- purrr::possibly(
  function(id) ngr::ngr_hyd_realtime(id, days_back = DAYS_BACK),
  otherwise = NULL
)

yr      <- format(today, "%Y")
mo      <- format(today, "%m")
out_dir <- fs::path("data", "realtime", yr, mo, paste0("snapshot_", today))
# Clean any leftovers from a prior same-day run; otherwise stale chunks
# would mix with new ones and the reader would double-count rows.
if (fs::dir_exists(out_dir)) fs::dir_delete(out_dir)
fs::dir_create(out_dir, recurse = TRUE)

chunks   <- split(stations, ceiling(seq_along(stations) / CHUNK_SIZE))
n_chunks <- length(chunks)

for (i in seq_along(chunks)) {
  message("Chunk ", i, "/", n_chunks, " (", length(chunks[[i]]), " stations)")
  dat <- chunks[[i]] |>
    purrr::map(pull_station) |>
    purrr::discard(is.null) |>
    dplyr::bind_rows() |>
    dplyr::mutate(harvested_at = now)

  if (nrow(dat) > 0) {
    out_file <- fs::path(out_dir, sprintf("chunk_%03d.parquet", i))
    arrow::write_parquet(dat, out_file)
    message("  wrote ", out_file, " — ", format(nrow(dat), big.mark = ","), " rows")
  } else {
    message("  no data in this chunk")
  }

  rm(dat); gc(verbose = FALSE)
}

# --- Verify + summary --------------------------------------------------------
written <- fs::dir_ls(out_dir, glob = "*.parquet")
if (length(written) == 0) {
  stop("Snapshot produced 0 chunks — refusing to leave an empty snapshot dir. ",
       "Investigate before the next monthly run.")
}

ds <- arrow::open_dataset(out_dir)
stopifnot("Date column missing from snapshot" = "Date" %in% ds$schema$names)

summary_row <- ds |>
  dplyr::summarise(
    rows     = dplyr::n(),
    stations = dplyr::n_distinct(STATION_NUMBER),
    min_date = min(Date, na.rm = TRUE),
    max_date = max(Date, na.rm = TRUE)
  ) |>
  dplyr::collect()

message(
  "Snapshot complete: ", out_dir, "\n",
  "  chunks:            ", length(written), "\n",
  "  rows:              ", format(summary_row$rows, big.mark = ","), "\n",
  "  distinct stations: ", summary_row$stations, "\n",
  "  date range:        ", format(summary_row$min_date), " -> ",
                            format(summary_row$max_date), "\n",
  "  harvested_at:      ", format(now)
)
