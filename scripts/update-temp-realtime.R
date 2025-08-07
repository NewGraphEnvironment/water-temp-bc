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

DBI::dbDisconnect(con)

#append to main parquet-----------------------------------------------------------------------------------------------------
# for each station in the main parquet get the Parameter and max(Date) so that we can scrape hydat
# just for the realtime data we don't have yet.  We still scrape all the station options though
# b/c some new ones may have come online - those get the default


con <- DBI::dbConnect(duckdb::duckdb())

# name the main parquet
path <- "data/realtime_raw_20250521.parquet"


query <- glue::glue(
  "SELECT
    STATION_NUMBER,
    Parameter,
    MIN(Date) AS min_date,
    MAX(Date) AS max_date
  FROM '{path}'
  -- turn it off
  -- WHERE Parameter = '5'
  GROUP BY STATION_NUMBER, Parameter;
"
)

res_stations_raw <- DBI::dbGetQuery(con, query)

res_stations <- res_stations_raw |>
  dplyr::mutate(
    days_since = as.integer(lubridate::today() - as.Date(max_date))
    )





purrr::map2_dfr(
  .x = res_stations$STATION_NUMBER,
  .y = res_stations$days_since,
  .f = ~ngr_hyd_realtime(
    id_station = .x,
    param_primary = res_stations$Parameter,
    param_secondary = NULL,
    days_back = .y
  )
)


#test of append workflow-----------------------------------------------------------------------------------------------------
