# here we will restamp our realtime_raw.parquet with its latest date

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/water-temp-bc.duckdb", read_only = FALSE)


# Get max(Date) where Code = 'TW'
date_max <- DBI::dbGetQuery(con, "
  SELECT MAX(Date) AS max_date
  FROM realtime_raw
  WHERE Parameter = '5'
")$max_date

# Format the date
out_table <- paste0("realtime_raw_", format(date_max, "%Y%m%d"))
out_file <- paste0("data/", "realtime_raw_", format(date_max, "%Y%m%d"), ".parquet")


# Export the table
DBI::dbExecute(con, glue::glue(
  "COPY realtime_raw TO '{out_file}' (FORMAT PARQUET)"
))

