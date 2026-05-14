# scripts/query-helpers.R
#
# Read-time canonical query helper for water-temp-bc.
#
# The dataset at s3://water-temp-bc/data/realtime/<yyyy>/<mm>/snapshot_*.parquet
# is append-only: every monthly run overlaps the prior ~18 months, so the same
# (STATION_NUMBER, Parameter, Date) row can appear in many snapshots. The
# canonical value at any (station, parameter, timestamp) is the one with the
# most recent `harvested_at` — that's the most-recently-published version,
# including QC corrections ECCC may have applied to older readings.
#
# query_canonical() encapsulates this dedup so callers never have to think
# about `harvested_at`. It returns a lazy dplyr query — call `collect()`
# yourself when you want the data in memory.
#
# Note: the slice_max step uses arrow::to_duckdb() because arrow's dplyr
# backend does not support `slice_max` over grouped data.

suppressPackageStartupMessages({
  library(dplyr)
  library(arrow)
})

#' Query the canonical (deduped) water-temp-bc realtime dataset.
#'
#' @param parameter Numeric Parameter code(s) to keep (e.g. 5 = water temp,
#'   6 = discharge). NULL = all.
#' @param stations Character STATION_NUMBER(s) to keep. NULL = all.
#' @param from,to Filters on `Date`. NULL = unbounded.
#'   - `Date`: treated as the whole calendar day in UTC (`to` is inclusive of
#'     the entire day, not just midnight).
#'   - `POSIXct`: converted to UTC; both bounds inclusive.
#'   - Character: parsed via `as.POSIXct(x, tz = "UTC")` (treated as UTC). Use
#'     a `POSIXct` if you mean a non-UTC timestamp.
#' @param dataset_root Top of the partitioned dataset on S3. Default points at
#'   the canonical bucket. Override to point at a local copy or staging path.
#'
#' @return A lazy `dplyr` query (duckdb-backed). Call `dplyr::collect()` to
#'   materialize.
query_canonical <- function(parameter    = NULL,
                            stations     = NULL,
                            from         = NULL,
                            to           = NULL,
                            dataset_root = "s3://water-temp-bc/data/realtime/") {
  ds <- arrow::open_dataset(dataset_root)
  q  <- ds

  # `as.POSIXct.Date` silently ignores `tz = "UTC"` and uses the system local
  # zone, which would shift the boundary by the local offset (8h in PT).
  # Force UTC explicitly.
  to_utc <- function(x) {
    if (inherits(x, "Date"))   return(as.POSIXct(format(x), tz = "UTC"))
    if (inherits(x, "POSIXt")) return(lubridate::with_tz(x, "UTC"))
    as.POSIXct(x, tz = "UTC")
  }

  if (!is.null(parameter)) q <- q |> dplyr::filter(Parameter %in% !!parameter)
  if (!is.null(stations))  q <- q |> dplyr::filter(STATION_NUMBER %in% !!stations)
  if (!is.null(from))      q <- q |> dplyr::filter(Date >= !!to_utc(from))

  # For Date `to`, widen to "strictly before next-day midnight" so the whole
  # calendar day is included. For POSIXct/character `to`, treat as inclusive
  # of the given instant.
  if (!is.null(to)) {
    if (inherits(to, "Date")) {
      q <- q |> dplyr::filter(Date < !!to_utc(to + 1))
    } else {
      q <- q |> dplyr::filter(Date <= !!to_utc(to))
    }
  }

  # Bridge to duckdb because arrow's dplyr backend doesn't support slice over
  # grouped data. Keep the lazy surface so callers can chain more dplyr verbs.
  q |>
    arrow::to_duckdb() |>
    dplyr::group_by(STATION_NUMBER, Parameter, Date) |>
    dplyr::slice_max(harvested_at, n = 1, with_ties = FALSE) |>
    dplyr::ungroup()
}
