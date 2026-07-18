# scripts/compact-functions.R
#
# Core compaction logic for the canonical store (#23): dedup overlapping raw
# snapshots to the latest harvested_at per (STATION_NUMBER, Parameter, Date)
# and write a hive-partitioned (Parameter=<int>/) zstd parquet store with rows
# ordered by (STATION_NUMBER, Date) so parquet row-group stats prune station
# and date queries. Per hive convention the Parameter column lives in the
# directory name only, not inside the files.
#
# Everything here is local and S3-free — scripts/compact.R orchestrates the
# transfer around these functions; scripts/compact-test.R pins the contract.

suppressPackageStartupMessages({
  library(DBI)
  library(fs)
})

# Escape a value for embedding in a single-quoted SQL literal.
sql_q <- function(x) gsub("'", "''", x)

# Which snapshot dirs need merging, given the canonical store's watermark.
# Inclusive comparison: a same-day re-pull reuses its dir name, and re-merging
# an already-merged snapshot is a dedup no-op — inclusive is therefore safe
# and makes every run idempotent.
compact_select_inputs <- function(dir_names, watermark_date = NULL) {
  if (is.null(watermark_date)) return(dir_names)
  d <- as.Date(sub("^snapshot_", "", basename(dir_names)), format = "%Y-%m-%d")
  dir_names[!is.na(d) & d >= as.Date(watermark_date)]
}

# Merge raw snapshot dirs (Parameter as a double column) and, optionally, an
# existing canonical store (Parameter as int in the hive path) into a fresh
# canonical store at out_dir. `params` restricts processing to the given
# Parameter values so the orchestrator can bound disk by handling one
# partition per pass; NULL processes every parameter found in the inputs.
compact_run <- function(snapshot_dirs, out_dir, canonical_dir = NULL,
                        params = NULL, null_frac_max = 0.001,
                        row_group_size = 122880L,
                        memory_limit = NULL, temp_dir = NULL) {
  if (length(snapshot_dirs) == 0) stop("compact_run: no snapshot dirs given")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  if (!is.null(memory_limit)) {
    DBI::dbExecute(con, sprintf("SET memory_limit = '%s'", sql_q(memory_limit)))
  }
  if (!is.null(temp_dir)) {
    fs::dir_create(temp_dir, recurse = TRUE)
    DBI::dbExecute(con, sprintf("SET temp_directory = '%s'", sql_q(temp_dir)))
  }

  snap_globs <- sprintf("'%s'", sql_q(as.character(fs::path(snapshot_dirs, "*.parquet"))))
  snap_sql <- sprintf("SELECT * FROM read_parquet([%s], union_by_name = true)",
                      paste(snap_globs, collapse = ", "))
  # UNION ALL BY NAME promotes canonical's int Parameter (from the hive path)
  # with the snapshots' double column, and tolerates future column additions.
  input_sql <- if (is.null(canonical_dir)) snap_sql else sprintf(
    "%s UNION ALL BY NAME SELECT * FROM read_parquet('%s', hive_partitioning = true, union_by_name = true)",
    snap_sql, sql_q(as.character(fs::path(canonical_dir, "**", "*.parquet"))))
  DBI::dbExecute(con, sprintf("CREATE TEMP VIEW inputs AS %s", input_sql))

  cnt <- DBI::dbGetQuery(con, "
    SELECT count(*)::BIGINT AS total,
           coalesce(sum(CASE WHEN Date IS NULL OR Parameter IS NULL THEN 1 ELSE 0 END), 0)::BIGINT AS nulls
    FROM inputs")
  if (cnt$total == 0) stop("compact_run: zero input rows")
  null_frac <- cnt$nulls / cnt$total
  if (null_frac > null_frac_max) {
    stop(sprintf(
      "compact_run: %d of %d input rows (%.3f%%) have NULL Date/Parameter — exceeds null_frac_max = %g. Investigate the raw snapshots before compacting.",
      cnt$nulls, cnt$total, 100 * null_frac, null_frac_max))
  }

  found <- DBI::dbGetQuery(con, "
    SELECT DISTINCT CAST(Parameter AS INTEGER) AS p
    FROM inputs WHERE Parameter IS NOT NULL ORDER BY p")$p
  todo <- if (is.null(params)) found else intersect(as.integer(params), found)

  if (fs::dir_exists(out_dir)) fs::dir_delete(out_dir)
  fs::dir_create(out_dir, recurse = TRUE)

  written <- integer(0)
  for (p in todo) {
    pdir <- fs::path(out_dir, sprintf("Parameter=%d", p))
    fs::dir_create(pdir)
    # Parameter is constant within the pass, so the window partitions only on
    # (STATION_NUMBER, Date). Tiebreakers past harvested_at make re-runs
    # byte-reproducible when a pull contains exact-key duplicates.
    n <- DBI::dbExecute(con, sprintf("
      COPY (
        SELECT * EXCLUDE (Parameter)
        FROM inputs
        WHERE Date IS NOT NULL AND Parameter IS NOT NULL
          AND CAST(Parameter AS INTEGER) = %d
        QUALIFY row_number() OVER (
          PARTITION BY STATION_NUMBER, Date
          ORDER BY harvested_at DESC,
                   Value DESC NULLS LAST,
                   Grade DESC NULLS LAST,
                   Approval DESC NULLS LAST
        ) = 1
        ORDER BY STATION_NUMBER, Date
      ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE %d)",
      p, sql_q(as.character(fs::path(pdir, "part-0.parquet"))),
      as.integer(row_group_size)))
    written[as.character(p)] <- n
  }

  invisible(list(
    rows_in      = as.numeric(cnt$total),
    rows_written = sum(written),
    null_dropped = as.numeric(cnt$nulls),
    params       = as.integer(todo),
    per_param    = written))
}

# Invariant gate: refuse to publish a canonical store that violates the
# contract readers rely on. Stops with a specific message; TRUE otherwise.
compact_verify <- function(out_dir, prev_rows = 0,
                           date_min_floor = as.POSIXct("2020-01-01", tz = "UTC"),
                           date_max_ceiling = Sys.time() + 48 * 3600) {
  fail <- function(...) stop("compact_verify: ", sprintf(...), call. = FALSE)
  parts <- fs::dir_ls(out_dir, type = "directory")
  if (length(parts) == 0) fail("no Parameter= partitions under %s", out_dir)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  s <- DBI::dbGetQuery(con, sprintf("
    WITH store AS (
      SELECT STATION_NUMBER, Parameter, Date
      FROM read_parquet('%s', hive_partitioning = true)
    )
    SELECT count(*)::BIGINT AS n,
           (SELECT count(*) FROM (SELECT DISTINCT STATION_NUMBER, Parameter, Date FROM store))::BIGINT AS n_keys,
           coalesce(sum(CASE WHEN Date IS NULL THEN 1 ELSE 0 END), 0)::BIGINT AS null_dates,
           min(Date) AS mn, max(Date) AS mx
    FROM store",
    sql_q(as.character(fs::path(out_dir, "**", "*.parquet")))))

  if (s$n == 0) fail("store is empty")
  if (s$n != s$n_keys) {
    fail("duplicate keys: %d rows vs %d distinct (STATION_NUMBER, Parameter, Date)", s$n, s$n_keys)
  }
  if (s$null_dates > 0) fail("%d NULL Date rows", s$null_dates)
  if (s$n < prev_rows) fail("row count regressed: %d < previous %d", s$n, prev_rows)
  if (s$mn < date_min_floor) fail("min Date %s below floor %s", s$mn, date_min_floor)
  if (s$mx > date_max_ceiling) fail("max Date %s beyond ceiling %s", s$mx, date_max_ceiling)
  invisible(TRUE)
}
