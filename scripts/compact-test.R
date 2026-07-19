#!/usr/bin/env Rscript
# scripts/compact-test.R
#
# Contract tests for scripts/compact-functions.R (the testable core of the
# monthly compaction, #23). Everything runs locally on tiny fixtures — no S3,
# no mocking. Run: Rscript scripts/compact-test.R  (non-zero exit on failure).
#
# Contract under test:
#   compact_select_inputs(dir_names, watermark_date) -> subset of dir names
#     with snapshot_<date> >= watermark_date (inclusive); NULL watermark -> all
#   compact_run(snapshot_dirs, out_dir, canonical_dir = NULL,
#               null_frac_max = 0.001, row_group_size = 122880L,
#               memory_limit = NULL, temp_dir = NULL) -> list(rows_written,
#     rows_in, null_dropped, params)
#     - dedup: latest harvested_at per (STATION_NUMBER, Parameter, Date),
#       ties broken deterministically (Value DESC NULLS LAST)
#     - drops NULL Date / NULL Parameter rows; errors if their fraction of
#       input rows exceeds null_frac_max
#     - output: hive dirs Parameter=<int>/part-<k>.parquet, zstd, each file
#       ORDER BY STATION_NUMBER, Date; partitions hash-shard by station into
#       ceiling(input_rows / shard_rows) files so aggregate state fits memory
#     - canonical_dir (hive-partitioned, Parameter int32 in path) merges with
#       raw snapshots (Parameter double column) transparently
#   compact_verify(out_dir, prev_rows = 0, date_min_floor, date_max_ceiling)
#     -> stops on violated invariant, else invisible(TRUE)

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(fs)
})

source("scripts/compact-functions.R")

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

TEST_ROOT <- fs::path(tempdir(), "compact-test")
if (fs::dir_exists(TEST_ROOT)) fs::dir_delete(TEST_ROOT)
fs::dir_create(TEST_ROOT)

utc <- function(x) as.POSIXct(x, tz = "UTC")

# Fixture rows mirror the real snapshot schema's load-bearing columns AND
# their real types — Grade is a double in production (a string sentinel in
# the dedup ordering once broke only on real data). Code stands in for the
# passthrough columns (Name_En, Unit, ...) that compaction must preserve
# without knowing about.
make_rows <- function(station, param, dates, values, harvested,
                      grade = 10, approval = "Provisional") {
  tibble::tibble(
    STATION_NUMBER = station,
    Date           = utc(dates),
    Value          = values,
    Grade          = as.numeric(grade),
    Approval       = approval,
    Parameter      = as.numeric(param),
    Code           = "PASSTHRU",
    harvested_at   = utc(harvested)
  )
}

write_snapshot <- function(name, df) {
  dir <- fs::path(TEST_ROOT, "raw", name)
  fs::dir_create(dir, recurse = TRUE)
  arrow::write_parquet(df, fs::path(dir, "chunk_001.parquet"))
  dir
}

out_dir <- local({
  i <- 0L
  function() {
    i <<- i + 1L
    fs::path(TEST_ROOT, sprintf("out_%02d", i))
  }
})

read_canonical <- function(dir) {
  arrow::open_dataset(dir) |> dplyr::collect() |>
    dplyr::arrange(Parameter, STATION_NUMBER, Date)
}

same_content <- function(a, b) {
  isTRUE(all.equal(as.data.frame(a)[order(names(a))],
                   as.data.frame(b)[order(names(b))],
                   check.attributes = FALSE))
}

# --- fixtures ----------------------------------------------------------------
# snapA (oldest pull): station S1 param 5, four dates incl. d0 which ages out
# of later windows; station S2 param 46 for the second hive partition.
d0 <- "2025-01-01 08:00:00"; d1 <- "2025-06-01 08:00:00"
d2 <- "2025-06-01 09:00:00"; d3 <- "2025-06-01 10:00:00"
h1 <- "2026-05-14 12:00:00"; h2 <- "2026-06-01 12:00:00"; h3 <- "2026-07-01 12:00:00"

snapA <- write_snapshot("snapshot_2026-05-14", dplyr::bind_rows(
  make_rows("S1", 5, c(d0, d1, d2, d3), c(1, 2, 3, 4), h1),
  make_rows("S2", 46, c(d1, d2), c(100, 101), h1)
))
# snapB (newer pull, window no longer covers d0): QC-corrected values for d1-d3
snapB <- write_snapshot("snapshot_2026-06-01", dplyr::bind_rows(
  make_rows("S1", 5, c(d1, d2, d3), c(20, 30, 40), h2, grade = 9, approval = "Approved"),
  make_rows("S2", 46, c(d1, d2), c(100, 101), h2)
))
# snapC: a third station appears
snapC <- write_snapshot("snapshot_2026-07-01", dplyr::bind_rows(
  make_rows("S1", 5, c(d1, d2, d3), c(20, 30, 40), h3),
  make_rows("S3", 5, d3, 7, h3)
))

# --- T0: watermark input selection -------------------------------------------
section("T0 watermark selection (inclusive, basename-tolerant)")
dirs <- c("snapshot_2026-05-14", "snapshot_2026-06-01", "snapshot_2026-07-01")
check("NULL watermark selects all",
      identical(compact_select_inputs(dirs, NULL), dirs))
check("watermark 2026-06-01 keeps June + July (inclusive)",
      identical(compact_select_inputs(dirs, as.Date("2026-06-01")), dirs[2:3]))
check("watermark after all selects none",
      length(compact_select_inputs(dirs, as.Date("2026-08-01"))) == 0)
check("full paths tolerated",
      identical(basename(compact_select_inputs(fs::path("x/y", dirs), as.Date("2026-07-01"))),
                dirs[3]))

# --- T1/T2: QC correction wins, aged-out date survives -----------------------
section("T1/T2 dedup semantics across overlapping snapshots")
o1 <- out_dir()
r1 <- compact_run(c(snapA, snapB), o1)
got <- read_canonical(o1)
s1 <- got |> dplyr::filter(STATION_NUMBER == "S1", Parameter == 5) |> dplyr::arrange(Date)
check("QC-corrected values win (newer harvested_at)",
      identical(s1$Value[s1$Date %in% utc(c(d1, d2, d3))], c(20, 30, 40)))
check("QC-corrected Grade/Approval ride along",
      all(s1$Grade[s1$Date == utc(d1)] == 9, s1$Approval[s1$Date == utc(d1)] == "Approved"))
check("aged-out date d0 (only in oldest snapshot) survives",
      nrow(s1[s1$Date == utc(d0), ]) == 1 && s1$Value[s1$Date == utc(d0)] == 1)
check("row accounting: rows_in = 11, rows_written = 6 S1+S2 keys",
      r1$rows_in == 11 && r1$rows_written == 6 && nrow(got) == 6)
check("passthrough column preserved", all(got$Code == "PASSTHRU"))

# --- T3: harvested_at tie -> deterministic winner ----------------------------
section("T3 tie determinism")
snapT <- write_snapshot("snapshot_2026-08-01", dplyr::bind_rows(
  make_rows("S1", 5, d1, 5, h3),
  make_rows("S1", 5, d1, 7, h3)   # same key, same harvested_at, higher Value
))
oT1 <- out_dir(); oT2 <- out_dir()
compact_run(snapT, oT1)
compact_run(snapT, oT2)
tied1 <- read_canonical(oT1); tied2 <- read_canonical(oT2)
check("single survivor for tied key", nrow(tied1) == 1)
check("tiebreaker is Value DESC (documented, stable)", tied1$Value == 7)
check("two runs produce identical content", same_content(tied1, tied2))

# --- T4: NULL Date / NULL Parameter dropped, counted, thresholded ------------
section("T4 NULL-key guard")
bad <- dplyr::bind_rows(
  make_rows("S1", 5, c(d1, d2), c(1, 2), h1),
  make_rows("S1", 5, d3, 3, h1) |> dplyr::mutate(Date = utc(NA)),
  make_rows("S1", 5, d3, 4, h1) |> dplyr::mutate(Parameter = NA_real_)
)
snapN <- write_snapshot("snapshot_2026-09-01", bad)
oN <- out_dir()
rN <- compact_run(snapN, oN, null_frac_max = 0.9)
gotN <- read_canonical(oN)
check("NULL-key rows dropped from output",
      nrow(gotN) == 2 && !any(is.na(gotN$Date)))
check("dropped rows counted", rN$null_dropped == 2)
check("no NULL hive partition written",
      !any(grepl("__HIVE_DEFAULT_PARTITION__", fs::dir_ls(oN, recurse = TRUE))))
check("default threshold (0.1%) rejects this fixture",
      expect_error(compact_run(snapN, out_dir())))

# --- T5: catch-up — canonical + two unmerged snapshots -----------------------
section("T5 catch-up merge (canonical + N snapshots == all-raw bootstrap)")
oCanA  <- out_dir()
compact_run(snapA, oCanA)                                  # canonical as of May
oCatch <- out_dir()
compact_run(c(snapB, snapC), oCatch, canonical_dir = oCanA) # catch up June+July
oFull  <- out_dir()
compact_run(c(snapA, snapB, snapC), oFull)                  # bootstrap-from-raw
check("catch-up equals bootstrap over the same snapshots",
      same_content(read_canonical(oCatch), read_canonical(oFull)))

# --- T6: re-merge idempotency ------------------------------------------------
section("T6 idempotency (re-merging a merged snapshot is a no-op)")
oIdem <- out_dir()
compact_run(snapB, oIdem, canonical_dir = oFull)  # snapB already inside oFull
check("content unchanged after re-merge",
      same_content(read_canonical(oIdem), read_canonical(oFull)))

# --- T7: hive layout, int32 Parameter, directory pruning ---------------------
section("T7 hive partitioning + arrow read-back")
part_dirs <- basename(fs::dir_ls(oFull, type = "directory"))
check("hive dirs use integer values (Parameter=5, not 5.0)",
      setequal(part_dirs, c("Parameter=5", "Parameter=46")))
sch <- arrow::open_dataset(oFull)$schema
check("arrow infers Parameter as int32",
      sch$GetFieldByName("Parameter")$type$ToString() == "int32")
only5 <- arrow::open_dataset(oFull) |> dplyr::filter(Parameter == 5) |> dplyr::collect()
dir5  <- arrow::open_dataset(fs::path(oFull, "Parameter=5")) |> dplyr::collect()
check("filter(Parameter == 5) returns exactly the Parameter=5 partition",
      nrow(only5) == nrow(dir5) && all(only5$Parameter == 5L))
check("params reported by compact_run", setequal(r1$params, c(5L, 46L)))

# --- T8: ordered write -> stratified row groups ------------------------------
# duckdb clamps ROW_GROUP_SIZE to a floor (~2048), so the fixture must exceed
# it to prove the writer honors the setting.
section("T8 row-group ordering (ORDER BY STATION_NUMBER, Date)")
day_seq <- format(seq(utc("2025-01-01 00:00:00"), by = "hour", length.out = 900),
                  "%Y-%m-%d %H:%M:%S")
many <- dplyr::bind_rows(lapply(sprintf("S%02d", 1:6), function(s)
  make_rows(s, 5, day_seq, seq_along(day_seq), h1)))
snapM <- write_snapshot("snapshot_2026-10-01", many)
oM <- out_dir()
compact_run(snapM, oM, row_group_size = 2048L)
f5 <- fs::dir_ls(fs::path(oM, "Parameter=5"), glob = "*.parquet")
check("exactly one file per partition", length(f5) == 1)
reader <- arrow::ParquetFileReader$create(f5[[1]])
check("row_group_size respected (multiple row groups)", reader$num_row_groups > 1)
raw_order <- arrow::read_parquet(f5[[1]])
check("physical row order is (STATION_NUMBER, Date)",
      identical(order(raw_order$STATION_NUMBER, raw_order$Date), seq_len(nrow(raw_order))))

con <- DBI::dbConnect(duckdb::duckdb())
codec <- DBI::dbGetQuery(con, sprintf(
  "SELECT DISTINCT compression FROM parquet_metadata('%s')", f5[[1]]))$compression
DBI::dbDisconnect(con, shutdown = TRUE)
check("zstd codec on data pages", all(grepl("ZSTD", codec, ignore.case = TRUE)))

# --- T8b: station-hash sharding (memory-bounding at scale) -------------------
section("T8b sharding (shard_rows forces multi-file partitions)")
oS <- out_dir()
compact_run(snapM, oS, shard_rows = 3000, row_group_size = 2048L)
fS <- fs::dir_ls(fs::path(oS, "Parameter=5"), glob = "*.parquet")
check("multiple shard files written", length(fS) >= 2)
check("sharded content equals unsharded content",
      same_content(read_canonical(oS), read_canonical(oM)))
per_file_stations <- lapply(fS, function(f)
  unique(arrow::read_parquet(f, col_select = "STATION_NUMBER")$STATION_NUMBER))
check("no station spans two shard files",
      sum(lengths(per_file_stations)) == length(unique(unlist(per_file_stations))))
check("each shard file internally ordered",
      all(vapply(fS, function(f) {
        x <- arrow::read_parquet(f, col_select = c("STATION_NUMBER", "Date"))
        identical(order(x$STATION_NUMBER, x$Date), seq_len(nrow(x)))
      }, logical(1))))

# --- T9: invariant gate ------------------------------------------------------
section("T9 compact_verify invariants")
check("clean store passes", isTRUE(compact_verify(oFull, prev_rows = 0)))
check("rowcount regression rejected",
      expect_error(compact_verify(oFull, prev_rows = 10^6)))
dup_dir <- fs::path(TEST_ROOT, "bad_dup", "Parameter=5")
fs::dir_create(dup_dir, recurse = TRUE)
arrow::write_parquet(
  dplyr::bind_rows(make_rows("S1", 5, d1, 1, h1), make_rows("S1", 5, d1, 2, h2)) |>
    dplyr::mutate(Parameter = NULL),
  fs::path(dup_dir, "part-0.parquet"))
check("duplicate keys rejected",
      expect_error(compact_verify(fs::path(TEST_ROOT, "bad_dup"), prev_rows = 0)))
future_dir <- fs::path(TEST_ROOT, "bad_future", "Parameter=5")
fs::dir_create(future_dir, recurse = TRUE)
arrow::write_parquet(
  make_rows("S1", 5, "2031-01-01 00:00:00", 1, h1) |> dplyr::mutate(Parameter = NULL),
  fs::path(future_dir, "part-0.parquet"))
check("far-future dates rejected",
      expect_error(compact_verify(fs::path(TEST_ROOT, "bad_future"), prev_rows = 0)))

# --- summary -----------------------------------------------------------------
cat(sprintf("\n%s — %d failure(s)\n", if (failures == 0) "ALL TESTS PASSED" else "TESTS FAILED", failures))
quit(status = if (failures == 0) 0L else 1L)
