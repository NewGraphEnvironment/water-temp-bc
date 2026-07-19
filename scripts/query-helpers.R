# scripts/query-helpers.R
#
# Canonical query helper for water-temp-bc.
#
# The canonical store at s3://water-temp-bc/data/canonical/Parameter=<n>/ is
# already deduplicated at build time: the monthly compaction
# (scripts/compact.R, #23) keeps the row with the most recent `harvested_at`
# per (STATION_NUMBER, Parameter, Date), so QC corrections ECCC applies to
# older readings win over earlier provisional values. Readers never see
# duplicates and never pay a dedup cost.
#
# The store is hive-partitioned by Parameter (int). A `parameter` filter
# prunes whole directories, so single-parameter queries read a small fraction
# of the dataset. Raw overlapping snapshots remain under data/realtime/ for
# provenance — query those only if you need pre-correction history.
#
# query_canonical() returns a lazy dplyr query — call `collect()` yourself
# when you want the data in memory.

suppressPackageStartupMessages({
  library(dplyr)
  library(arrow)
})

# Open a dataset with explicit S3 timeouts. The default S3 client retries a
# transient DNS/network failure with long backoff (observed: 8.7 min before
# erroring); these bounds make it fail in seconds instead. anonymous = TRUE:
# the bucket policy grants public GetObject + ListBucket (rtj#187), so no
# one needs AWS credentials — and expired/misconfigured local credentials
# can't break reads either.
open_dataset_canonical <- function(dataset_root) {
  if (grepl("^s3://", dataset_root)) {
    fs <- arrow::S3FileSystem$create(
      anonymous       = TRUE,
      region          = "us-west-2",
      connect_timeout = 10,
      request_timeout = 60
    )
    arrow::open_dataset(sub("^s3://", "", dataset_root), filesystem = fs)
  } else {
    arrow::open_dataset(dataset_root)
  }
}

#' Query the canonical (deduped, Parameter-partitioned) water-temp-bc dataset.
#'
#' @param parameter Numeric Parameter code(s) to keep (e.g. 5 = water temp,
#'   47 = realtime discharge). NULL = all. Note the partition column comes
#'   back as int32 (hive), not double.
#' @param stations Character STATION_NUMBER(s) to keep. NULL = all.
#' @param from,to Filters on `Date`. NULL = unbounded.
#'   - `Date`: treated as the whole calendar day in UTC (`to` is inclusive of
#'     the entire day, not just midnight).
#'   - `POSIXct`: converted to UTC; both bounds inclusive.
#'   - Character: parsed via `as.POSIXct(x, tz = "UTC")` (treated as UTC). Use
#'     a `POSIXct` if you mean a non-UTC timestamp.
#' @param dataset_root Top of the partitioned dataset on S3. Default points at
#'   the canonical store. Override to point at a local copy or staging path.
#'
#' @return A lazy `dplyr` query (duckdb-backed). Call `dplyr::collect()` to
#'   materialize.
query_canonical <- function(parameter    = NULL,
                            stations     = NULL,
                            from         = NULL,
                            to           = NULL,
                            dataset_root = "s3://water-temp-bc/data/canonical/") {
  q <- open_dataset_canonical(dataset_root)

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

  # Bridge to duckdb so the returned lazy query supports the full dplyr verb
  # set (e.g. grouped slice_max, which arrow's backend can't do) — the same
  # contract this helper has always returned.
  q |> arrow::to_duckdb()
}
