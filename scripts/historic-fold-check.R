#!/usr/bin/env Rscript
# scripts/historic-fold-check.R
#
# Acceptance checks for a canonical store that holds the folded historic
# record (#19). Read-only. Run against the dry-run store before publishing,
# and against S3 after:
#
#   Rscript scripts/historic-fold-check.R work/historic-fold/folded work/historic-fold/historic_normalized work/historic-fold/canonical_meta_before.json
#   Rscript scripts/historic-fold-check.R s3://water-temp-bc/data/canonical s3://water-temp-bc/data/historic/normalized
#
# Arguments: <store> (hive Parameter=<n>/ dirs), <normalized> (the four
# normalized historic files) and, for a local store, [meta_before] (the
# canonical meta from before the fold; its historic_merged$rows_before if
# present, else its `rows`, are the pre-fold counts).
# For the S3 store the pre-fold counts come from the live meta's
# historic_merged$rows_before. Exits non-zero if any check fails.
#
# Each check is independent of how the store was built:
#   - no duplicate (STATION_NUMBER, Parameter, Date)
#   - every normalized historic key is present in the store
#   - rows harvested by snapshots (>= FIRST_SNAPSHOT) against the pre-fold
#     canonical rows, per parameter: no canonical row was lost or replaced by
#     a historic one. EQUAL while the store is still at the watermark the fold
#     ran at (historic_merged$at_last_merged); after a later monthly merge,
#     which only adds keys, >= — weaker, so run this check before the next
#     monthly run. (Row counts vs meta$rows alone would be circular — the
#     fold writes meta$rows from its own output.)
#   - ICE rows == distinct ICE keys in the normalized eccc file (every ICE
#     flag is on an eccc key; research/historic-archive.md)
#   - no Grade -1, no NULL Unit, no NULL Date
#   - daily discharge (p6): at most one row per station per UTC date (the
#     feed stamps a day at 07:00 or 08:00 UTC)
#   - one schema across every file; one row collected per partition by arrow
#   - rows per parameter == canonical_meta.json (S3 store only)

args <- commandArgs(trailingOnly = TRUE)
if (!length(args) %in% 2:3) stop("usage: historic-fold-check.R <store> <normalized> [meta_before]")
store <- sub("/$", "", args[1])
normalized <- sub("/$", "", args[2])
on_s3 <- grepl("^s3://", store)
if (!on_s3 && length(args) < 3) stop("a local store needs [meta_before], the pre-fold canonical meta")
source("scripts/historic-functions.R")  # FIRST_SNAPSHOT
source("scripts/query-helpers.R")      # open_dataset_canonical()

failures <- 0L
check <- function(desc, cond) {
  ok <- isTRUE(cond)
  cat(sprintf("  %s: %s\n", if (ok) "PASS" else "FAIL", desc))
  if (!ok) failures <<- failures + 1L
  invisible(ok)
}

con <- DBI::dbConnect(duckdb::duckdb())
if (grepl("^s3://", store) || grepl("^s3://", normalized)) {
  DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs; SET s3_region = 'us-west-2'")
}
DBI::dbExecute(con, "SET preserve_insertion_order = false")
q <- function(sql) DBI::dbGetQuery(con, sql)
sq <- function(x) gsub("'", "''", x)

st <- sprintf("read_parquet('%s/**/*.parquet', hive_partitioning = true)", sq(store))
nm <- sprintf("read_parquet('%s/*.parquet')", sq(normalized))
cat("store:      ", store, "\nnormalized: ", normalized, "\n\n", sep = "")

cat("== rows and keys per parameter\n")
per <- q(sprintf("
  SELECT Parameter AS p, count(*)::BIGINT AS rows,
         count(DISTINCT (STATION_NUMBER, Date))::BIGINT AS keys,
         strftime(min(CAST(Date AS TIMESTAMP)), '%%Y-%%m-%%d') AS first,
         strftime(max(CAST(Date AS TIMESTAMP)), '%%Y-%%m-%%d') AS last
  FROM %s GROUP BY 1 ORDER BY 1", st))
print(per, row.names = FALSE)
check("no duplicate (STATION_NUMBER, Parameter, Date)", all(per$rows == per$keys))
check("earliest Date is 2002-04-30 (ECCC water temperature)", min(per$first) == "2002-04-30")

cat("\n== historic keys present in the store\n")
missing <- q(sprintf("
  SELECT CAST(h.Parameter AS INTEGER) AS p, count(*)::BIGINT AS missing
  FROM (SELECT DISTINCT STATION_NUMBER, Parameter, CAST(Date AS TIMESTAMP) AS d FROM %s) h
  ANTI JOIN (SELECT STATION_NUMBER, Parameter, CAST(Date AS TIMESTAMP) AS d FROM %s) s
    ON s.STATION_NUMBER = h.STATION_NUMBER AND s.Parameter = CAST(h.Parameter AS INTEGER) AND s.d = h.d
  GROUP BY 1", nm, st))
check("every normalized historic key is in the store", nrow(missing) == 0)
if (nrow(missing) > 0) print(missing, row.names = FALSE)

cat("\n== canonical rows kept, and canonical won every overlap\n")
meta_live <- NULL
exact <- FALSE
if (on_s3) {
  meta_url <- sub("/canonical$", "/canonical_meta.json", store)
  meta_live <- jsonlite::fromJSON(rawToChar(
    q(sprintf("SELECT content FROM read_blob('%s')", sq(meta_url)))$content[[1]]))
  before <- meta_live$historic_merged$rows_before
  at <- meta_live$historic_merged$at_last_merged
  exact <- !is.null(at) && identical(at, meta_live$last_merged)
} else {
  mb <- jsonlite::read_json(args[3])
  # Pre-fold meta: its rows. An already-folded meta (a re-fold's dry run):
  # its recorded rows_before — its rows include the historic rows.
  before <- if (is.null(mb$historic_merged)) mb$rows else mb$historic_merged$rows_before
  exact <- TRUE
}
# An empty list reads back from `{}` and would make every check below vacuous.
have_before <- length(before) > 0 &&
  all(vapply(before, function(v) is.numeric(v) && length(v) == 1 && !is.na(v), logical(1)))
check("pre-fold row counts available (non-empty, numeric)", have_before)
snap <- q(sprintf("
  SELECT Parameter AS p, count(*) FILTER (WHERE harvested_at >= TIMESTAMP '%s')::BIGINT AS from_snapshots
  FROM %s GROUP BY 1 ORDER BY 1", format(FIRST_SNAPSHOT, "%Y-%m-%d %H:%M:%S"), st))
snap$before <- vapply(as.character(snap$p), function(k) {
  v <- before[[k]]; if (is.null(v)) 0 else as.numeric(v) }, 0)
print(snap, row.names = FALSE)
if (exact) {
  check("rows from snapshots == pre-fold canonical rows, every parameter (store at the fold's watermark)",
        have_before && all(snap$from_snapshots == snap$before))
} else {
  cat("  (store has merged snapshots since the fold: comparing with >=)\n")
  check("rows from snapshots >= pre-fold canonical rows, every parameter",
        have_before && all(snap$from_snapshots >= snap$before))
}
check("every pre-fold parameter still present",
      have_before && all(names(before) %in% as.character(snap$p)))

cat("\n== vocabularies\n")
ice <- q(sprintf("SELECT count(*)::BIGINT AS n FROM %s WHERE Symbol = 'ICE'", st))$n
ice_src <- q(sprintf(
  "SELECT count(DISTINCT (STATION_NUMBER, Date))::BIGINT AS n FROM read_parquet('%s/realtime_raw_eccc_20221213.parquet') WHERE Symbol = 'ICE'",
  sq(normalized)))$n
check(sprintf("ICE rows (%s) == distinct eccc ICE keys (%s)", ice, ice_src), ice == ice_src && ice > 0)
bad <- q(sprintf("
  SELECT count(*) FILTER (WHERE Grade = -1)::BIGINT AS grade_m1,
         count(*) FILTER (WHERE Unit IS NULL)::BIGINT AS unit_null,
         count(*) FILTER (WHERE Date IS NULL)::BIGINT AS date_null
  FROM %s", st))
check("no Grade -1", bad$grade_m1 == 0)
check("no NULL Unit", bad$unit_null == 0)
check("no NULL Date", bad$date_null == 0)
print(q(sprintf("SELECT Approval, count(*)::BIGINT AS n FROM %s GROUP BY 1 ORDER BY 2 DESC", st)),
      row.names = FALSE)

cat("\n== daily discharge: one row per station per UTC date\n")
multi <- q(sprintf("
  SELECT count(*)::BIGINT AS n FROM (
    SELECT STATION_NUMBER, CAST(CAST(Date AS TIMESTAMP) AS DATE) AS d
    FROM %s WHERE Parameter = 6 GROUP BY ALL HAVING count(*) > 1)", st))$n
check("p6 station-days with more than one row: 0", multi == 0)

cat("\n== schema and arrow read-back\n")
schemas <- q(sprintf("
  SELECT count(DISTINCT sig)::INTEGER AS n_schemas, count(*)::INTEGER AS n_files FROM (
    SELECT file_name, string_agg(name || ':' || coalesce(type, '') || ':' || coalesce(logical_type, ''), ',' ORDER BY name) AS sig
    FROM parquet_schema('%s/**/*.parquet') GROUP BY file_name)", sq(store)))
check(sprintf("one schema across %d files", schemas$n_files), schemas$n_schemas == 1)
ds <- open_dataset_canonical(paste0(store, "/"))
for (p in per$p) {
  r <- ds |> dplyr::filter(Parameter == !!p) |> head(1) |> dplyr::collect()
  check(sprintf("p%d: arrow collects a row, Date tz UTC", p),
        nrow(r) == 1 && identical(attr(r$Date, "tzone"), "UTC"))
}

if (on_s3) {
  cat("\n== canonical_meta.json\n")
  meta <- meta_live
  meta_rows <- unlist(meta$rows)[as.character(per$p)]
  check("rows per parameter == meta$rows", identical(unname(as.numeric(meta_rows)), as.numeric(per$rows)))
  check("meta records the historic fold", !is.null(meta$historic_merged))
  if (!is.null(meta$historic_merged)) cat("  folded_at:", meta$historic_merged$folded_at, "\n")
}

DBI::dbDisconnect(con, shutdown = TRUE)
cat(sprintf("\n%s — %d failure(s)\n", if (failures == 0) "ALL CHECKS PASSED" else "CHECKS FAILED", failures))
quit(status = if (failures == 0) 0L else 1L)
