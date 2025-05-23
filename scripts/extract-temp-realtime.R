library(tidyhydat)
library(tidyverse)
library(DBI)
library(duckdb)


# see a list of parameters available
param_id <- param_id

# get alist of stations with realtime data (according to tidyhydat)
stations_tidyhydat <- tidyhydat::realtime_stations(prov_terr_state_loc = 'BC') |>
  pull(STATION_NUMBER)

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
  dplyr::bind_rows()

#Get past realtime data to amalgamate-----------------------------------------------------------------------------------------------------
# get the directory where past data was stored
dir <- "/Users/airvine/Projects/data/temp_realtime.sqlite"
conn <- readwritesqlite::rws_connect(dir)
readwritesqlite::rws_list_tables(conn)


dat_existing <- readwritesqlite::rws_read_table("temp_realtime", conn = conn) |>
  ngr::ngr_tidy_cols_rm_na()

# check for column type conflicts. requires named elements in the list
ngr::ngr_tidy_cols_type_compare(
  list(
    dat_raw2 = dat_raw2,
    dat_existing = dat_existing
  )
)

# deal with the type issue
dat_realtime <- ngr::ngr_tidy_type(dat_existing, dat_raw2)

# see duplicate rows where cols are shared.  Diffs in how cols are recorded means there are just a few
cols_common <- dplyr::intersect(names(dat_realtime), names(dat_existing))
dupes <- dplyr::intersect(
  dat_realtime |>
    dplyr::select(dplyr::all_of(cols_common)),
  dat_existing |>
    dplyr::select(dplyr::all_of(cols_common))
)

#see all dupe rows of the two dataframes considering select columns - values
cols_dupe <- c("STATION_NUMBER", "Date", "Value", "Parameter")
dupes_values <- dplyr::intersect(
  dat_existing |>
    dplyr::select(dplyr::all_of(cols_dupe)),
  dat_realtime |>
    dplyr::select(dplyr::all_of(cols_dupe))
)

# this should make sense when we look at the time range overlap where these dupes occur
dates_overlap <- dplyr::intersect(
  dat_existing |>
    dplyr::filter(Parameter == 5) |>
    dplyr::select(Date),

  dat_realtime |>
    dplyr::filter(Parameter == 5) |>
    dplyr::select(Date)
)

range(dates_overlap$Date)
range(dupes_values$Date)

# we have no dupes in our og dfs
dupes_realtime <- dat_realtime |>
  dplyr::filter(Parameter == 5) |>
  dplyr::group_by(dplyr::across(dplyr::all_of(cols_dupe))) |>
  dplyr::filter(dplyr::n() > 1) |>
  dplyr::ungroup()

dupes_existing <- dat_existing |>
  dplyr::filter(Parameter == 5) |>
  dplyr::group_by(dplyr::across(dplyr::all_of(cols_dupe))) |>
  dplyr::filter(dplyr::n() > 1) |>
  dplyr::ungroup()


# we have no dupes unless the dates of the dfs overlap - which makes sense
dates_view <- dplyr::setdiff(
  dates_overlap,
  dupes_values |>
    dplyr::select(Date)
)

# Combine tables without duplicates
# dplyr::union() concatenates the two data frames and then drops duplicate rows, keeping the first occurrence it encounters.
dat_amalgamated_ids <- dplyr::union(
  dat_realtime |>
    dplyr::select(dplyr::all_of(cols_dupe)),
  dat_existing |>
    dplyr::select(dplyr::all_of(cols_dupe))
)

# chk on duplicate number are removed
identical(
  nrow(dupes_values),
  nrow(dat_realtime) + nrow(dat_existing) - nrow(dat_amalgamated_ids)
)

# We still want to keep all of the other columns that we can so we need to join back those cols from the og dfs
dat_amalgamated_prep1 <- dplyr::left_join(
  dat_amalgamated_ids,
  dat_realtime
)

dat_existing_to_join <- dat_amalgamated_prep1 |>
  # Name_En is added so if it is not there yet we still need to join
  dplyr::filter(is.na(Name_En))

dat_amalgamated_prep2 <- dplyr::left_join(
  dat_existing_to_join,
  dat_existing
)

dat_amalgamated <- dplyr::bind_rows(
  dat_amalgamated_prep1 |>
    # we only want the ones not joined on first join yo
    dplyr::filter(!is.na(Name_En)),
  dat_amalgamated_prep2
)

identical(nrow(dat_amalgamated), nrow(dat_amalgamated_ids))

# from dat_amalgamated get summary of number of events for each Parameter
dat_sum <- dplyr::left_join(
  dat_amalgamated |>
    # one row per Parameter with its event count
  dplyr::count(Parameter, name = "n_events"),

  tidyhydat::param_id |>
    dplyr::select(Parameter, Code, Name_En),

  by = "Parameter"
)

range(
  dat_amalgamated |>
    dplyr::filter(Parameter == 5) |>
    dplyr::pull(Date)
)


#load duckdb-----------------------------------------------------------------------------------------------------

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/water-temp-bc.duckdb", read_only = FALSE)

# write our amalgamated data to the database
DBI::dbWriteTable(con, "realtime-raw", dat_amalgamated)

DBI::dbListTables(con)

# to big to write direct to s3 parquet
DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
DBI::dbExecute(con, "SET s3_region='us-west-2'")
DBI::dbExecute(con, paste0("SET s3_secret_access_key='", Sys.getenv("AWS_SECRET_ACCESS_KEY"), "'"))

DBI::dbExecute(con, paste0("SET s3_access_key_id='", Sys.getenv("AWS_ACCESS_KEY_ID"), "'"))


#this will work
DBI::dbExecute(con, "COPY (SELECT * FROM 'realtime-raw' LIMIT 10000000) TO 's3://water-temp-bc/test.parquet' (FORMAT PARQUET)")

# this will fail
DBI::dbExecute(con, "COPY 'realtime-raw' TO 's3://water-temp-bc/realtime-raw.parquet' (FORMAT PARQUET)")

# so we will just burn locally
DBI::dbExecute(con, "COPY 'realtime-raw' TO 'data/realtime-raw.parquet' (FORMAT PARQUET)")

