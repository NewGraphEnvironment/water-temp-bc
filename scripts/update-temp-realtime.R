# see a list of parameters available
param_id <- tidyhydat::param_id

# get alist of stations with realtime data (according to tidyhydat)
stations_tidyhydat <- tidyhydat::realtime_stations(prov_terr_state_loc = 'BC') |>
  dplyr::pull(STATION_NUMBER)

# stations forwarded from ECCC. See email.  Could be historic data only....
stations_eccc <- readxl::read_excel("data/eccc/BC_Stations_withTW.xlsx") |>
  dplyr::pull(stationid)

# get list of stations that removes duplicates but includes both
stations <- unique(c(stations_tidyhydat, stations_eccc))

# see the stations that we did not have from tidyhydat
setdiff(stations, stations_tidyhydat)

# get list of all params that contain discharge from param_id using stringr and dplyr::filter
# discharge_params <- param_id %>%
#   dplyr::filter(stringr::str_detect(Name_En, "Discharge")) |>
#   dplyr::pull(Parameter)

# get data for all stations
dat_raw <- stations |>
  purrr::map(ngr::ngr_hyd_realtime)

# put it all into one dataframe for now
dat_raw2 <- dat_raw |>
  purrr::discard(is.null) |>
  dplyr::bind_rows() |>
  # remove the empty columns
  ngr::ngr_tidy_cols_rm_na()

#

con <- DBI::dbConnect(duckdb::duckdb())

# get the latest date in the dataframe so we can append to the name
date_max <- max(dat_raw2$Date)
out_table <- paste0("realtime_raw_", format(date_max, "%Y%m%d"))
out_file <- paste0("data/", "realtime_raw_", format(date_max, "%Y%m%d"), ".parquet")


con <- DBI::dbConnect(duckdb::duckdb())
# Register the data frame as a DuckDB table
duckdb::duckdb_register(con, out_table, dat_raw2)

# we will just burn locally then sync
DBI::dbExecute(
  con,
  glue::glue("COPY {DBI::SQL(out_table)} TO '{out_file}' (FORMAT PARQUET)")
)
