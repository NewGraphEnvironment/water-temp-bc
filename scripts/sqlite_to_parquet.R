# we are going to burn our sqlite table that we extracted 2024-01-19 to a parquet in data so it can go to the bucket

dir <- "/Users/airvine/Projects/data/temp_realtime.sqlite"
conn <- readwritesqlite::rws_connect(dir)
readwritesqlite::rws_list_tables(conn)


dat_existing <- readwritesqlite::rws_read_table("temp_realtime", conn = conn) |>
  ngr::ngr_tidy_cols_rm_na()

con <- DBI::dbConnect(duckdb::duckdb())

# so we will just burn locally
DBI::dbExecute(con, "COPY realtime_raw TO 'data/realtime_raw_20240119.parquet' (FORMAT PARQUET)")
