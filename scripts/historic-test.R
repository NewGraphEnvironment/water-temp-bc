#!/usr/bin/env Rscript
# scripts/historic-test.R
#
# Contract tests for scripts/historic-functions.R (#19): normalizing the four
# pre-modernization files in s3://water-temp-bc/data/historic/ to the raw
# snapshot schema so compact_run() can fold them into canonical/. Local
# fixtures only — no S3. Run: Rscript scripts/historic-test.R
# (non-zero exit on failure).
#
# Fixtures are written through duckdb with explicit SQL types so each one
# mirrors a real file's schema, including its awkward types: naked
# timestamp[us] Date, string Value/Parameter (eccc), string Grade (20240119,
# 20250521), missing columns, and within-file duplicate keys (20250521).
#
# Contract under test:
#   historic_normalize(in_file, out_file) -> invisible(list(rows, harvested_at))
#     - output columns and types == the raw snapshot schema, in its order
#     - Date: naked timestamp stamped UTC with the wall clock unchanged
#     - Value / Parameter / Grade cast to double; a string that does not
#       parse is an error, never a silent NULL
#     - RangeNumber / Quality / Interpolation dropped; Symbol, Approval,
#       Code, Name_En passed through verbatim; absent columns become NULL
#     - NULL Unit filled from the Parameter code; a present Unit untouched
#     - harvested_at = the file's max Date (a lower bound on the pull time)
#     - no rows added, dropped or deduplicated, except that exclude_matching
#       removes rows equal on (STATION_NUMBER, Parameter, Date, Value) to a
#       row in the given older files (20250521's stripped copies)
#     - Grade -1 ("no grade" in the 2022-2024 feed) -> NULL
#     - rows written ORDER BY Parameter, STATION_NUMBER, Date

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(fs)
})

# The wall-clock assertions must not pass merely because the test machine
# happens to run in UTC.
Sys.setenv(TZ = "America/Vancouver")

source("scripts/compact-functions.R")
source("scripts/historic-functions.R")

# --- harness -----------------------------------------------------------------
failures <- 0L
check <- function(desc, cond) {
  ok <- isTRUE(cond)
  cat(sprintf("  %s: %s\n", if (ok) "PASS" else "FAIL", desc))
  if (!ok) failures <<- failures + 1L
  invisible(ok)
}
section <- function(title) cat("\n== ", title, " ==\n", sep = "")
expect_error <- function(expr) {
  tryCatch({ force(expr); FALSE }, error = function(e) TRUE)
}

TEST_ROOT <- fs::path(tempdir(), "historic-test")
if (fs::dir_exists(TEST_ROOT)) fs::dir_delete(TEST_ROOT)
fs::dir_create(fs::path(TEST_ROOT, c("in", "norm")), recurse = TRUE)

utc <- function(x) as.POSIXct(x, tz = "UTC")

# Write a fixture parquet from a SQL SELECT so column types are exact.
write_fixture <- function(name, select_sql) {
  f <- fs::path(TEST_ROOT, "in", paste0(name, ".parquet"))
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("COPY (%s) TO '%s' (FORMAT PARQUET)", select_sql, f))
  f
}

# The raw snapshot schema, read from s3://water-temp-bc/data/realtime/2026/09
# on 2026-09-28. compact_run() consumes exactly this shape.
SNAPSHOT_SCHEMA <- c(
  STATION_NUMBER = "string",
  Date           = "timestamp[us, tz=UTC]",
  Name_En        = "string",
  Value          = "double",
  Unit           = "string",
  Grade          = "double",
  Symbol         = "string",
  Approval       = "string",
  Parameter      = "double",
  Code           = "string",
  Qualifier      = "string",
  Qualifiers     = "bool",
  harvested_at   = "timestamp[us]"
)
schema_of <- function(f) {
  s <- arrow::ParquetFileReader$create(f)$GetSchema()
  stats::setNames(vapply(s$fields, function(x) x$type$ToString(), ""), s$names)
}

# --- fixtures ----------------------------------------------------------------
# Station S1, Parameter 6 (daily discharge, 08:00 UTC stamps) runs through
# every file so overlap precedence is observable on one series:
#   d_old  only in eccc                       -> eccc survives (Symbol ICE)
#   d_mid  in 20240119 (12) and 20250521 (11) -> 20250521 wins
#   d_new  in 20250521 (23) and 20250728 (22) -> 20250728 wins
#   d_can  in 20250728 (34) and canonical (33) -> canonical wins
# The newer value is always the LOWER one, so a fold that lost harvest order
# and fell through to compact_run()'s Value DESC tiebreak picks the wrong row.
d_old <- "2016-01-15 08:00:00"; d_mid <- "2023-01-15 08:00:00"
d_new <- "2025-01-15 08:00:00"; d_can <- "2025-06-15 08:00:00"

f_eccc <- write_fixture("realtime_raw_eccc_20221213", sprintf("
  SELECT * FROM (VALUES
    ('1', TIMESTAMP '%s', '1.5', NULL, '8', '1', 'ICE', 'S1', '6', 'QRD', 'Stn one'),
    ('1', TIMESTAMP '2002-04-30 08:03:00', '4.25', '-1', '1', '1', NULL, 'S1', '5', 'TW', 'Stn one'),
    ('1', TIMESTAMP '2002-04-30 08:03:00', '4.25', '-1', '1', '1', NULL, 'S1', '5', 'TW', 'Stn one')
  ) t(RangeNumber, Date, Value, Quality, Interpolation, Approval, Symbol,
      STATION_NUMBER, Parameter, Code, Name_En)", d_old))

f_2024 <- write_fixture("realtime_raw_20240119", sprintf("
  SELECT * FROM (VALUES
    ('S1', TIMESTAMP '%s', 'Stn one', 12.0::DOUBLE, 'm3/s', '-1', 'Provisional/Provisoire', 6.0::DOUBLE, 'QRD'),
    ('S1', TIMESTAMP '2023-01-15 19:15:00', 'Stn one', 2.0::DOUBLE, 'mm', '20', 'Final/Finales', 18.0::DOUBLE, 'PC')
  ) t(STATION_NUMBER, Date, Name_En, Value, Unit, Grade, Approval, Parameter, Code)", d_mid))

# 20250521 as it really is: copies of older rows with metadata stripped
# (removed by exclude_matching), a stale copy + revision pair on one key, and
# rows of its own.
f_2025a <- write_fixture("realtime_raw_20250521", sprintf("
  SELECT * FROM (VALUES
    ('S1', TIMESTAMP '%s', 12.0::DOUBLE, 6.0::DOUBLE, NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, 'QRD', 'Stn one', NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, NULL::BOOLEAN),
    ('S1', TIMESTAMP '%s', 11.0::DOUBLE, 6.0::DOUBLE, NULL, NULL, NULL, NULL, NULL, 'QRD', 'Stn one', NULL, NULL, NULL, NULL),
    ('S1', TIMESTAMP '%s', 1.5::DOUBLE, 6.0::DOUBLE, '1', NULL, '8', '1', 'ICE', 'QRD', 'Stn one', NULL, NULL, NULL, NULL),
    ('S1', TIMESTAMP '2023-01-15 19:15:00', 2.0::DOUBLE, 18.0::DOUBLE, NULL, NULL, NULL, NULL, NULL, 'PC', 'Stn one', NULL, NULL, NULL, NULL),
    ('S1', TIMESTAMP '%s', 23.0::DOUBLE, 6.0::DOUBLE, NULL, NULL, NULL, NULL, NULL, 'QRD', 'Stn one', NULL, NULL, NULL, NULL),
    ('S2', TIMESTAMP '2024-03-01 21:15:00', 0.75::DOUBLE, 46.0::DOUBLE, NULL, NULL, NULL, NULL, NULL, 'HG', 'Stn two', NULL, NULL, NULL, NULL)
  ) t(STATION_NUMBER, Date, Value, Parameter, RangeNumber, Quality, Interpolation,
      Approval, Symbol, Code, Name_En, Unit, Grade, Qualifier, Qualifiers)",
  d_mid, d_mid, d_old, d_new))

f_2025b <- write_fixture("realtime_raw_20250728", sprintf("
  SELECT * FROM (VALUES
    ('S1', TIMESTAMP '%s', 'Stn one', 22.0::DOUBLE, 'm3/s', 10.0::DOUBLE, NULL::VARCHAR, 'Provisional/Provisoire', 6.0::DOUBLE, 'QRD', '10', NULL::BOOLEAN),
    ('S1', TIMESTAMP '%s', 'Stn one', 34.0::DOUBLE, 'm3/s', NULL::DOUBLE, NULL::VARCHAR, 'Provisional/Provisoire', 6.0::DOUBLE, 'QRD', NULL, NULL::BOOLEAN)
  ) t(STATION_NUMBER, Date, Name_En, Value, Unit, Grade, Symbol, Approval,
      Parameter, Code, Qualifier, Qualifiers)", d_new, d_can))

norm <- function(f, exclude = character()) {
  out <- fs::path(TEST_ROOT, "norm", fs::path_file(f))
  historic_normalize(f, out, exclude_matching = exclude)
  out
}
n_eccc <- norm(f_eccc); n_2024 <- norm(f_2024)
n_2025a <- norm(f_2025a, exclude = c(f_eccc, f_2024)); n_2025b <- norm(f_2025b)
normed <- c(n_eccc, n_2024, n_2025a, n_2025b)
rd <- function(f) arrow::read_parquet(f)

# --- N1: schema --------------------------------------------------------------
section("N1 output schema == raw snapshot schema")
for (f in normed) {
  check(sprintf("%s: names, order and types match", fs::path_file(f)),
        identical(schema_of(f), SNAPSHOT_SCHEMA))
}

# --- N2: Date wall clock -----------------------------------------------------
section("N2 naked Date stamped UTC, wall clock unchanged (TZ=America/Vancouver)")
e <- rd(n_eccc)
check("eccc daily stamp still 08:00 UTC",
      utc(d_old) %in% e$Date && attr(e$Date, "tzone") == "UTC")
check("eccc sub-daily stamp unchanged (2002-04-30 08:03)",
      utc("2002-04-30 08:03:00") %in% e$Date)
check("20240119 stamps unchanged",
      setequal(rd(n_2024)$Date, utc(c(d_mid, "2023-01-15 19:15:00"))))

# --- N3: casts ---------------------------------------------------------------
section("N3 string Value / Parameter / Grade cast to double")
check("eccc Value '1.5' -> 1.5 and Parameter '6' -> 6",
      any(e$Value == 1.5 & e$Parameter == 6))
g <- rd(n_2024)
check("20240119 Grade '-1' (no grade) -> NA, '20' -> 20",
      identical(sort(g$Grade, na.last = TRUE), c(20, NA)))
check("20250521 all-NULL string Grade -> NA double",
      all(is.na(rd(n_2025a)$Grade)))
bad <- write_fixture("bad_value", "
  SELECT * FROM (VALUES ('S1', TIMESTAMP '2016-01-01 08:00:00', 'abc', '6'))
  t(STATION_NUMBER, Date, Value, Parameter)")
check("unparseable Value errors instead of becoming NULL",
      expect_error(historic_normalize(bad, fs::path(TEST_ROOT, "norm", "bad.parquet"))))

# --- N4: columns dropped / passed through ------------------------------------
section("N4 dropped and passthrough columns")
check("RangeNumber / Quality / Interpolation dropped",
      !any(c("RangeNumber", "Quality", "Interpolation") %in% names(e)))
check("eccc Symbol 'ICE' preserved", "ICE" %in% e$Symbol)
check("eccc Approval code '1' preserved verbatim", all(e$Approval == "1"))
check("20240119 Approval text preserved",
      setequal(g$Approval, c("Provisional/Provisoire", "Final/Finales")))
check("columns absent from 20240119 come back NULL",
      all(is.na(g$Symbol)) && all(is.na(g$Qualifier)) && all(is.na(g$Qualifiers)))
check("20250728 Qualifier passes through", "10" %in% rd(n_2025b)$Qualifier)

# --- N5: Unit ----------------------------------------------------------------
section("N5 NULL Unit filled from Parameter; present Unit untouched")
check("eccc p6 -> m3/s, p5 -> °C",
      all(e$Unit[e$Parameter == 6] == "m3/s") && all(e$Unit[e$Parameter == 5] == "°C"))
a <- rd(n_2025a)
check("20250521 NULL Unit filled (p6 m3/s, p46 m)",
      all(a$Unit[a$Parameter == 6] == "m3/s") && all(a$Unit[a$Parameter == 46] == "m"))
check("20240119 present Units untouched (p18 mm)",
      g$Unit[g$Parameter == 18] == "mm")
check("unit map covers every historic parameter",
      setequal(names(HISTORIC_UNITS), c("1", "5", "6", "18", "46", "47")))

# --- N6: harvested_at --------------------------------------------------------
section("N6 harvested_at = file max(Date)")
check("eccc harvested_at == its max Date", all(e$harvested_at == max(e$Date)))
check("20250728 harvested_at == its max Date",
      all(rd(n_2025b)$harvested_at == utc(d_can)))
hv <- vapply(normed, function(f) as.numeric(rd(f)$harvested_at[1]), 0)
check("files order eccc < 20240119 < 20250521 < 20250728", !is.unsorted(hv, strictly = TRUE))

# --- N7: row accounting ------------------------------------------------------
section("N7 no rows added, dropped or deduplicated")
check("eccc keeps its within-file duplicate (3 rows)", nrow(e) == 3)
res <- historic_normalize(f_2024, fs::path(TEST_ROOT, "norm", "again.parquet"))
check("historic_normalize reports rows written", res$rows == 2)
all6 <- historic_normalize(f_2025a, fs::path(TEST_ROOT, "norm", "all6.parquet"))
check("without exclude_matching every row is kept (6)", all6$rows == 6)

# --- N8: exclude_matching ----------------------------------------------------
section("N8 20250521: rows copied from older files removed on (key, Value)")
check("3 copies removed, 3 own rows kept", nrow(a) == 3)
check("the stale copy (12) is gone and the revision (11) stays",
      identical(a$Value[a$Date == utc(d_mid)], 11))
check("no duplicate key left in the file",
      nrow(dplyr::distinct(a, STATION_NUMBER, Parameter, Date)) == nrow(a))
check("rows ordered by Parameter first (eccc fixture is written p6 before p5)",
      !is.unsorted(rd(n_eccc)$Parameter))

# --- E1: fold into canonical via compact_run ---------------------------------
section("E1 fold: compact_run(normalized, canonical_dir = canonical)")
# Canonical fixture built the way production builds it: a raw snapshot
# (naked harvested_at, tz=UTC Date) compacted into hive Parameter=6/.
snap_dir <- fs::path(TEST_ROOT, "snapshot_2026-05-14")
fs::dir_create(snap_dir)
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, sprintf("COPY (SELECT 'S1' AS STATION_NUMBER,
    CAST('%s+00' AS TIMESTAMPTZ) AS Date, 'Stn one' AS Name_En, 33.0::DOUBLE AS Value,
    'm3/s' AS Unit, NULL::DOUBLE AS Grade, NULL::VARCHAR AS Symbol,
    'Provisional/Provisoire' AS Approval, 6.0::DOUBLE AS Parameter, 'QRD' AS Code,
    NULL::VARCHAR AS Qualifier, NULL::BOOLEAN AS Qualifiers,
    TIMESTAMP '2026-05-14 21:06:19' AS harvested_at)
  TO '%s' (FORMAT PARQUET)", d_can, fs::path(snap_dir, "chunk_001.parquet")))
DBI::dbDisconnect(con, shutdown = TRUE)
check("snapshot fixture has the raw snapshot schema",
      identical(schema_of(fs::path(snap_dir, "chunk_001.parquet"))[names(SNAPSHOT_SCHEMA)],
                SNAPSHOT_SCHEMA))
can_dir <- fs::path(TEST_ROOT, "canonical")
compact_run(snap_dir, can_dir)

out <- fs::path(TEST_ROOT, "folded")
# compact_run globs <dir>/*.parquet; stage the four normalized files as one dir.
norm_set <- fs::path(TEST_ROOT, "norm_set")
fs::dir_create(norm_set)
fs::file_copy(normed, norm_set, overwrite = TRUE)
# shard_keys = 2 forces several station-hash shards across historic and
# canonical rows together.
r <- compact_run(norm_set, out, canonical_dir = can_dir, shard_keys = 2)
got <- arrow::open_dataset(out) |> dplyr::collect()
s1 <- got |> dplyr::filter(STATION_NUMBER == "S1", Parameter == 6L)
val_at <- function(d) s1$Value[s1$Date == utc(d)]
check("eccc-only key survives with Symbol ICE",
      identical(val_at(d_old), 1.5) && s1$Symbol[s1$Date == utc(d_old)] == "ICE")
check("20250521 revision beats 20240119 and its own stale copy", identical(val_at(d_mid), 11))
p18 <- got |> dplyr::filter(Parameter == 18L)
check("20240119 Grade/Approval survive where 20250521 only copied the row",
      nrow(p18) == 1 && p18$Grade == 20 && p18$Approval == "Final/Finales")
check("eccc Approval code survives where 20250521 only copied the row",
      s1$Approval[s1$Date == utc(d_old)] == "1")
check("20250728 beats 20250521 on overlap", identical(val_at(d_new), 22))
check("canonical beats 20250728 on overlap", identical(val_at(d_can), 33))
check("parameters 5, 6, 18, 46 all partitioned",
      setequal(r$params, c(5L, 6L, 18L, 46L)))
check("no duplicate keys after fold",
      nrow(dplyr::distinct(got, STATION_NUMBER, Parameter, Date)) == nrow(got))
check("folded store passes compact_verify (2002 dates, default floor)",
      isTRUE(compact_verify(out, prev_rows = 1)))
check("folded store reads as one arrow dataset with Date tz=UTC",
      arrow::open_dataset(out)$schema$GetFieldByName("Date")$type$ToString() ==
        "timestamp[us, tz=UTC]")

# --- V1: compact_verify floor ------------------------------------------------
section("V1 compact_verify date floor admits the historic record")
old_dir <- fs::path(TEST_ROOT, "too_old", "Parameter=5")
fs::dir_create(old_dir, recurse = TRUE)
arrow::write_parquet(
  tibble::tibble(STATION_NUMBER = "S1", Date = utc("2001-12-31 00:00:00"), Value = 1),
  fs::path(old_dir, "part-0.parquet"))
check("dates before 2002 still rejected",
      expect_error(compact_verify(fs::path(TEST_ROOT, "too_old"), prev_rows = 0)))

# --- summary -----------------------------------------------------------------
cat(sprintf("\n%s — %d failure(s)\n", if (failures == 0) "ALL TESTS PASSED" else "TESTS FAILED", failures))
quit(status = if (failures == 0) 0L else 1L)
