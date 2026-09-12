#!/usr/bin/env Rscript
# scripts/snapshot-test.R
#
# Contract tests for scripts/snapshot-functions.R (the testable core of the
# monthly snapshot's station resolution, #27). Everything runs locally on tiny
# fixtures — no network, no mocking framework: the live fetch is an injected
# function. Run: Rscript scripts/snapshot-test.R  (non-zero exit on failure).
#
# Contract under test:
#   snapshot_stations(fetch_live, bundled, eccc_ids = character(0),
#                     tries = 3L, wait = 30) -> list(ids, source, attempts, error)
#     - fetch_live(): zero-arg function returning station ids (character).
#       It is called up to `tries` times, sleeping `wait` s between calls. A
#       call "fails" when it errors OR returns no non-NA ids — zero rows is
#       what tidyhydat::realtime_stations("BC") yields on a 404 (its all-NA
#       placeholder row is dropped by the province filter).
#       Retrying here is required, not redundant: tidyhydat's own req_retry()
#       leaves httr2's retry_on_failure = FALSE, so a failed connection is
#       never retried (the #27 failure).
#     - first success -> source "live", ids = live ∪ eccc_ids; `error` is the
#       last failure's message if an earlier attempt failed, else NA
#     - every try fails -> source "fallback", ids = bundled rows with
#       PROV_TERR_STATE_LOC == "BC" and REAL_TIME TRUE (NA is not TRUE),
#       ∪ eccc_ids; `error` carries the last failure's message
#     - ids: character, no NA, no duplicates; attempts = calls made
#     - an empty final station list is an error, never an empty snapshot
#
# Every check must FAIL against an implementation that just crashes — a check
# a crash can satisfy cannot detect the failure it is named for. Verified by
# running this file against a stub that always stop()s: 31/31 FAIL.

source("scripts/snapshot-functions.R")

# --- harness -----------------------------------------------------------------
failures <- 0L
check <- function(desc, cond) {
  ok <- isTRUE(cond)
  cat(sprintf("  %s: %s\n", if (ok) "PASS" else "FAIL", desc))
  if (!ok) failures <<- failures + 1L
  invisible(ok)
}
section <- function(title) cat("\n== ", title, " ==\n", sep = "")
# Matches the message, so the check proves the named guard fired — not merely
# that something, anything, errored.
expect_error <- function(expr, pattern) {
  tryCatch({ force(expr); FALSE },
           error = function(e) grepl(pattern, conditionMessage(e)))
}
# A case that errors must fail its checks, not abort the run — otherwise the
# restore-the-bug check (an implementation that lets fetch errors propagate)
# would stop at the first case instead of reporting every one it breaks. The
# crash message goes in its own field: putting it in `error` would let an
# implementation that simply crashes pass the "error captured" checks.
run_case <- function(expr) {
  tryCatch(expr, error = function(e) list(ids = NULL, source = NA_character_,
                                          attempts = NA_integer_,
                                          error = NA_character_,
                                          crashed = conditionMessage(e)))
}
same_set <- function(x, y) is.character(x) && setequal(x, y) && !anyDuplicated(x)
# nzchar(NA) is TRUE, so a bare nzchar() check passes on a missing message.
filled <- function(x) length(x) == 1L && !is.na(x) && nzchar(x)

# Counts calls, so attempts can be checked against what actually happened.
fetcher <- function(results) {
  n <- 0L
  f <- function() {
    n <<- n + 1L
    r <- results[[min(n, length(results))]]
    if (inherits(r, "error")) stop(r)
    r
  }
  list(f = f, calls = function() n)
}
fail_connect <- simpleError(
  "Failed to connect to dd.weather.gc.ca port 443 after 10002 ms: Timeout was reached")

# Types mirror tidyhydat::allstations: STATION_NUMBER / PROV_TERR_STATE_LOC
# character, REAL_TIME logical. Rows chosen so the fallback filter has
# something to exclude on each arm: another province, REAL_TIME FALSE, and
# REAL_TIME NA. The NA row pins the outcome (no NA id, no stray station), not
# the mechanism: the filter's %in% and clean() each exclude it, so this row
# cannot tell them apart. Production has no NA REAL_TIME today; defensive.
bundled <- data.frame(
  STATION_NUMBER      = c("08AA001", "08BB002", "07CC003", "08DD004", "08EE005", "08FF006"),
  PROV_TERR_STATE_LOC = c("BC",      "BC",      "AB",      "BC",      "BC",      "BC"),
  REAL_TIME           = c(TRUE,      TRUE,      TRUE,      FALSE,     TRUE,      NA),
  stringsAsFactors = FALSE
)
bundled_bc_rt <- c("08AA001", "08BB002", "08EE005")
# Overlaps the bundled list (08AA001) and carries an NA, as readxl yields for
# a blank cell (the tracked xlsx has none today; defensive).
eccc <- c("08ZZ999", "08AA001", NA)
eccc_clean <- c("08ZZ999", "08AA001")
live <- c("08AA001", "08QQ111")

# --- T1 ----------------------------------------------------------------------
section("T1 live succeeds first try -> live ∪ eccc")
f <- fetcher(list(live))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 3L, wait = 0))
check("source is live", identical(r$source, "live"))
check("ids = live ∪ eccc", same_set(r$ids, union(live, eccc_clean)))
check("one attempt", identical(r$attempts, 1L) && f$calls() == 1L)
check("no error recorded", is.null(r$crashed) && is.na(r$error))

# --- T2 ----------------------------------------------------------------------
section("T2 error then success -> retried, live, first failure kept")
f <- fetcher(list(fail_connect, live))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 3L, wait = 0))
check("source is live", identical(r$source, "live"))
check("ids = live ∪ eccc", same_set(r$ids, union(live, eccc_clean)))
check("two attempts", identical(r$attempts, 2L) && f$calls() == 2L)
check("earlier failure's message kept", filled(r$error) && grepl("Failed to connect", r$error))

# --- T3 ----------------------------------------------------------------------
section("T3 error on every try -> fallback to bundled BC realtime")
f <- fetcher(list(fail_connect))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 3L, wait = 0))
check("source is fallback", identical(r$source, "fallback"))
check("ids = bundled BC REAL_TIME ∪ eccc", same_set(r$ids, union(bundled_bc_rt, eccc_clean)))
check("attempts == tries", identical(r$attempts, 3L) && f$calls() == 3L)
check("last error captured", filled(r$error) && grepl("Failed to connect", r$error))

# --- T4 ----------------------------------------------------------------------
section("T4 all-NA ids -> fallback (defensive; unfiltered 404 placeholder row)")
f <- fetcher(list(NA_character_))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 2L, wait = 0))
check("source is fallback", identical(r$source, "fallback"))
check("ids = bundled BC REAL_TIME ∪ eccc", same_set(r$ids, union(bundled_bc_rt, eccc_clean)))
# is.character() first: anyNA(NULL) is FALSE, so a crash would pass alone.
check("NA not in ids", is.character(r$ids) && !anyNA(r$ids))
check("retried like an error", identical(r$attempts, 2L) && f$calls() == 2L)

# --- T5 ----------------------------------------------------------------------
section("T5 zero rows (tidyhydat's 404 shape once filtered to BC) -> fallback")
f <- fetcher(list(character(0)))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 2L, wait = 0))
check("source is fallback", identical(r$source, "fallback"))
check("ids = bundled BC REAL_TIME ∪ eccc", same_set(r$ids, union(bundled_bc_rt, eccc_clean)))
check("failure message recorded", filled(r$error))
check("retried like an error", identical(r$attempts, 2L) && f$calls() == 2L)

# --- T6 ----------------------------------------------------------------------
section("T6 NA and duplicate ids dropped")
f <- fetcher(list(c("08AA001", NA, "08AA001", "08QQ111")))
r <- run_case(snapshot_stations(f$f, bundled, eccc, tries = 1L, wait = 0))
check("ids is character", is.character(r$ids))
check("no NA", is.character(r$ids) && !anyNA(r$ids))
check("no duplicates", length(r$ids) > 0 && !anyDuplicated(r$ids))
check("ids = live ∪ eccc", same_set(r$ids, union(live, eccc_clean)))

# --- T7 ----------------------------------------------------------------------
section("T7 fallback filter excludes other provinces, REAL_TIME FALSE and NA")
f <- fetcher(list(fail_connect))
r <- run_case(snapshot_stations(f$f, bundled, tries = 1L, wait = 0))
check("default eccc_ids works", identical(r$source, "fallback"))
check("AB station excluded", !is.null(r$ids) && !("07CC003" %in% r$ids))
check("REAL_TIME FALSE excluded", !is.null(r$ids) && !("08DD004" %in% r$ids))
check("REAL_TIME NA excluded", !is.null(r$ids) && !("08FF006" %in% r$ids))
check("exactly the BC realtime rows", same_set(r$ids, bundled_bc_rt))

# --- T8 ----------------------------------------------------------------------
section("T8 empty final list is an error")
f <- fetcher(list(fail_connect))
none <- bundled[bundled$PROV_TERR_STATE_LOC == "AB", ]
check("live fails + no fallback rows + no eccc -> error",
      expect_error(snapshot_stations(f$f, none, tries = 1L, wait = 0),
                   "no stations to pull"))
check("bundled missing REAL_TIME column -> error, not an empty fallback",
      expect_error(snapshot_stations(fetcher(list(fail_connect))$f,
                                     bundled[, c("STATION_NUMBER", "PROV_TERR_STATE_LOC")],
                                     eccc, tries = 1L, wait = 0),
                   "missing column"))

# --- summary -----------------------------------------------------------------
cat("\n")
if (failures > 0L) {
  cat(sprintf("%d check(s) FAILED\n", failures))
  quit(status = 1L)
}
cat("All checks passed\n")
