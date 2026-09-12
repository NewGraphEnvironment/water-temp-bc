# scripts/snapshot-functions.R
#
# Testable core of the monthly snapshot's station resolution (#27). Sourced by
# scripts/snapshot.R; contract-tested by scripts/snapshot-test.R.

# Resolve the station list to pull. The live list comes from the ECCC datamart
# (dd.weather.gc.ca), which the GHA runner has failed to connect to — so it is
# retried here and, if it never answers, replaced by the station table bundled
# with tidyhydat. Either way the ECCC-forwarded ids are unioned in.
#
# Retrying here is required, not redundant: tidyhydat wraps its requests in
# httr2::req_retry(), whose retry_on_failure defaults to FALSE, so a failed
# connection is never retried (the 2026-08/09 failures died after one 10 s
# connect timeout). An empty result counts as a failure too: on a 404,
# tidyhydat::realtime_stations() does not error — its all-NA placeholder row
# is dropped by the province filter, leaving zero rows.
#
# fetch_live: zero-arg function returning station ids
# bundled:    data frame with STATION_NUMBER, PROV_TERR_STATE_LOC, REAL_TIME
#             (tidyhydat::allstations)
# Returns list(ids, source = "live" | "fallback", attempts, error). `error` is
# the last failure's message whenever any attempt failed, including a live
# result reached after a retry — that is the "flaky, not blocked" evidence.
snapshot_stations <- function(fetch_live, bundled, eccc_ids = character(0),
                              tries = 3L, wait = 30) {
  tries <- as.integer(tries)
  stopifnot(length(tries) == 1L, tries >= 1L)

  clean <- function(x) {
    x <- as.character(x)
    unique(x[!is.na(x) & nzchar(x)])
  }
  eccc_ids <- clean(eccc_ids)
  err <- NA_character_

  for (attempt in seq_len(tries)) {
    res <- tryCatch(fetch_live(), error = function(e) e)
    if (inherits(res, "error")) {
      err <- conditionMessage(res)
    } else {
      live <- clean(res)
      if (length(live) > 0L) {
        return(list(ids = union(live, eccc_ids), source = "live",
                    attempts = attempt, error = err))
      }
      err <- "live station list returned no station ids"
    }
    if (attempt < tries) Sys.sleep(wait)
  }

  # A renamed column would otherwise filter to nothing and read as "no BC
  # realtime stations" rather than as a broken fallback.
  need <- c("STATION_NUMBER", "PROV_TERR_STATE_LOC", "REAL_TIME")
  missing <- setdiff(need, names(bundled))
  if (length(missing) > 0L) {
    stop("bundled station table is missing column(s): ",
         paste(missing, collapse = ", "), call. = FALSE)
  }
  # %in% reads NA in either column as FALSE; == would make an NA index and so
  # an NA id, which clean() then drops — %in% just never produces it.
  keep <- bundled$PROV_TERR_STATE_LOC %in% "BC" & bundled$REAL_TIME %in% TRUE
  ids <- union(clean(bundled$STATION_NUMBER[keep]), eccc_ids)
  if (length(ids) == 0L) {
    stop("no stations to pull: the live list failed (", err,
         ") and the fallback is empty", call. = FALSE)
  }
  list(ids = ids, source = "fallback", attempts = tries, error = err)
}
