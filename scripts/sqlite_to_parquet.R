# we have a historic table
# we are going to burn the sqlite table that we extracted 2024-01-19 to a parquet in data so it can go to the bucket
# with `scripts/sync-data.R`

dir <- "/Users/airvine/Projects/data/temp_realtime.sqlite"
conn <- readwritesqlite::rws_connect(dir)
readwritesqlite::rws_list_tables(conn)

dat_existing <- readwritesqlite::rws_read_table("temp_realtime", conn = conn) |>
  ngr::ngr_tidy_cols_rm_na()

# so we will just burn locally
date_max <- max(dat_existing$Date)
out_table <- paste0("realtime_raw_", format(date_max, "%Y%m%d"))
out_file <- paste0("data/", "realtime_raw_", format(date_max, "%Y%m%d"), ".parquet")

con <- DBI::dbConnect(duckdb::duckdb())
# Register the data frame as a DuckDB table
duckdb::duckdb_register(con, out_table, dat_existing)

# we will just burn locally then sync
DBI::dbExecute(
  con,
  glue::glue("COPY {DBI::SQL(out_table)} TO '{out_file}' (FORMAT PARQUET)")
)

