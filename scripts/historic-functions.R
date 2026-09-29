# scripts/historic-functions.R
#
# Normalize one pre-modernization file from s3://water-temp-bc/data/historic/
# (#19) to the raw snapshot schema, so scripts/historic-fold.R can merge it
# into the canonical store through compact_run() like any other snapshot.
#
# The four historic files disagree on types and columns (measured 2026-09-28,
# research/historic-archive.md): Date is a naked timestamp[us] that holds UTC
# wall-clock; the ECCC dump stores Value and Parameter as strings; Grade is a
# string in two files; Unit is missing or NULL in two. The projection below
# makes every file look like a snapshot chunk. It drops rows in exactly one
# case, `exclude_matching` below; otherwise dedup belongs to compact_run().
#
# Everything here is local and S3-free; scripts/historic-test.R pins the
# contract.

suppressPackageStartupMessages({
  library(DBI)
  library(fs)
})

if (!exists("sql_q")) sql_q <- function(x) gsub("'", "''", x)

# The four frozen originals under data/historic/, oldest pull first. The
# normalized copies under data/historic/normalized/ carry the same names.
HISTORIC_FILES <- c(
  "realtime_raw_eccc_20221213.parquet",
  "realtime_raw_20240119.parquet",
  "realtime_raw_20250521.parquet",
  "realtime_raw_20250728.parquet"
)

# Unit by Parameter code, for files whose Unit column is missing or NULL.
# Taken from the 20240119 file, the one historic file that carries Unit for
# every parameter: its Unit x Parameter crosstab is one-to-one.
HISTORIC_UNITS <- c(
  "1"  = "°C",  # air temperature
  "5"  = "°C",  # water temperature
  "6"  = "m3/s",     # discharge, daily mean
  "18" = "mm",       # precipitation
  "46" = "m",        # water level
  "47" = "m3/s"      # discharge, sensor derived
)

# Column -> SQL type of the raw snapshot schema, in its order.
SNAPSHOT_COLUMNS <- c(
  STATION_NUMBER = "VARCHAR",
  Date           = "TIMESTAMPTZ",
  Name_En        = "VARCHAR",
  Value          = "DOUBLE",
  Unit           = "VARCHAR",
  Grade          = "DOUBLE",
  Symbol         = "VARCHAR",
  Approval       = "VARCHAR",
  Parameter      = "DOUBLE",
  Code           = "VARCHAR",
  Qualifier      = "VARCHAR",
  Qualifiers     = "BOOLEAN",
  harvested_at   = "TIMESTAMP"
)

# exclude_matching: files whose rows, matched on (STATION_NUMBER, Parameter,
# Date, Value), are removed from in_file. For 20250521 only. That file is an
# amalgamation of the eccc dump, 20240119 and newer pulls, deduplicated on
# (key, Value), so 52.0M of its 134.0M rows are copies of older rows with
# their Grade/Approval stripped, and each of its 3.14M duplicate keys is one
# such stale copy plus a revision (measured 2026-09-28). Its later
# harvested_at would otherwise let the stripped copies overwrite the
# originals, and leave old-vs-revised to compact_run()'s Value tiebreak.
# Excluding the copies leaves no duplicate key in the file.
historic_normalize <- function(in_file, out_file, exclude_matching = character()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "SET preserve_insertion_order = false")

  src <- sprintf("read_parquet('%s')", sql_q(as.character(in_file)))
  have <- DBI::dbGetQuery(con, sprintf("DESCRIBE SELECT * FROM %s", src))
  types <- stats::setNames(have$column_type, have$column_name)
  for (req in c("STATION_NUMBER", "Date", "Value", "Parameter")) {
    if (!req %in% names(types)) stop("historic_normalize: ", in_file, " has no ", req, " column")
  }
  if (!types[["Date"]] %in% c("TIMESTAMP", "TIMESTAMP WITH TIME ZONE")) {
    stop("historic_normalize: unexpected Date type ", types[["Date"]], " in ", in_file)
  }

  # CAST, not TRY_CAST: a string that does not parse must stop the run, not
  # become a NULL that every later check accepts.
  col <- function(name, type) {
    if (!name %in% names(types)) return(sprintf("NULL::%s AS \"%s\"", type, name))
    sprintf("CAST(\"%s\" AS %s) AS \"%s\"", name, type, name)
  }
  # A naked timestamp here is UTC wall clock (research/historic-archive.md).
  # Build the TIMESTAMPTZ from text with an explicit +00 offset: a plain
  # CAST(TIMESTAMP AS TIMESTAMPTZ) reads the session TimeZone once duckdb's
  # icu extension is loaded, which would shift every row by the local offset.
  date_sql <- if (types[["Date"]] == "TIMESTAMP") {
    "CAST(strftime(\"Date\", '%Y-%m-%d %H:%M:%S.%f') || '+00' AS TIMESTAMPTZ) AS \"Date\""
  } else {
    "\"Date\""
  }
  unit_case <- sprintf("CASE CAST(\"Parameter\" AS DOUBLE) %s END",
                       paste(sprintf("WHEN %s THEN '%s'", names(HISTORIC_UNITS),
                                     sql_q(HISTORIC_UNITS)), collapse = " "))
  unit_sql <- if ("Unit" %in% names(types)) {
    sprintf("coalesce(CAST(\"Unit\" AS VARCHAR), %s) AS \"Unit\"", unit_case)
  } else {
    sprintf("%s AS \"Unit\"", unit_case)
  }

  harvested <- DBI::dbGetQuery(con, sprintf(
    "SELECT strftime(max(CAST(\"Date\" AS TIMESTAMP)), '%%Y-%%m-%%d %%H:%%M:%%S.%%f') AS h FROM %s",
    src))$h
  if (is.na(harvested)) stop("historic_normalize: ", in_file, " has no non-NULL Date")

  # Grade -1 is the 2022-2024 feed's "no grade"; the feed has sent NULL for
  # that since (20250728 and canonical never hold -1).
  grade_sql <- if ("Grade" %in% names(types)) {
    "nullif(CAST(\"Grade\" AS DOUBLE), -1) AS \"Grade\""
  } else {
    "NULL::DOUBLE AS \"Grade\""
  }

  select <- vapply(names(SNAPSHOT_COLUMNS), function(n) {
    switch(n,
      Date         = date_sql,
      Unit         = unit_sql,
      Grade        = grade_sql,
      harvested_at = sprintf("TIMESTAMP '%s' AS \"harvested_at\"", harvested),
      col(n, SNAPSHOT_COLUMNS[[n]]))
  }, character(1))

  where <- ""
  if (length(exclude_matching) > 0) {
    old <- paste(sprintf(
      "SELECT STATION_NUMBER, CAST(Parameter AS DOUBLE) AS p, CAST(Date AS TIMESTAMP) AS d,
              CAST(Value AS DOUBLE) AS v FROM read_parquet('%s')",
      sql_q(as.character(exclude_matching))), collapse = " UNION ALL ")
    where <- sprintf(
      "WHERE NOT EXISTS (SELECT 1 FROM (%s) o
         WHERE o.STATION_NUMBER = s.STATION_NUMBER
           AND o.p = CAST(s.Parameter AS DOUBLE)
           AND o.d = CAST(s.Date AS TIMESTAMP)
           AND o.v IS NOT DISTINCT FROM CAST(s.Value AS DOUBLE))", old)
  }

  # Ordered by Parameter first so parquet row-group stats let compact_run()'s
  # per-Parameter passes skip the other parameters' rows.
  fs::dir_create(fs::path_dir(out_file), recurse = TRUE)
  rows <- DBI::dbExecute(con, sprintf(
    "COPY (SELECT %s FROM %s s %s ORDER BY Parameter, STATION_NUMBER, Date)
     TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    paste(select, collapse = ",\n  "), src, where, sql_q(as.character(out_file))))

  invisible(list(rows = rows, harvested_at = as.POSIXct(harvested, tz = "UTC")))
}
