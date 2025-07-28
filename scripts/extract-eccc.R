#Station Data from ECCC-----------------------------------------------------------------------------------------------------
# we need to have mdb-tools installed via brew on our macbook to run this
path_mdb <- "data/eccc/WaterTemperature_1994to2016.mdb"
dat_eccc_all <- Hmisc::mdb.get(
  path_mdb,
  stringsAsFactors = FALSE,
  lowernames=TRUE,
  allow = "_"
)

names(dat_eccc_all)

dat_eccc_raw <- dat_eccc_all |>
  purrr::pluck("Envcanada_dailyt_data_envcanada")


stations_eccc <- dat_eccc_all |>
  purrr::pluck("Envcanada_ec_tw_stations_location") |>
  dplyr::filter(province == "BC")



# get the data just for the stations in BC
dat_eccc_raw2 <- dplyr::left_join(

  dat_eccc_raw |>
    ngr::ngr_tidy_type(stations_eccc),

  stations_eccc |>
    dplyr::select(stationname),

  by = "stationname"
)

#temp data before 20220111-----------------------------------------------------------------------------------------------------
source("scripts/functions.R")

path_dir <- c(
  "/Users/airvine/Projects/repo/water-temp-bc/data/eccc/TW_UnitValues_before_20220111",
  "/Users/airvine/Projects/repo/water-temp-bc/data/eccc/QR_ProvisionalDailyValues_20151231_to_20221216",
  "/Users/airvine/Projects/repo/water-temp-bc/data/eccc/TW_UnitValues_20220110_to_20221213"
)

paths <- path_dir |>
  purrr::map(fs::dir_ls) |>
  unlist(use.names = FALSE)

dat_realtime_raw <- purrr::map(paths, eccc_csv_extract) |>
  dplyr::bind_rows()

# Get max(Date) where Code = 'TW'
date_max <- max(
  dat_realtime_raw |>
  dplyr::filter(Parameter == 5) |>
  dplyr::pull(Date)
)

# Format the date
out_table <- paste0("realtime_raw_", format(date_max, "%Y%m%d"))
out_file <- paste0("data/", "realtime_raw_eccc_", format(date_max, "%Y%m%d"), ".parquet")

# burn the raw dataframe to parquet
con <- DBI::dbConnect(duckdb::duckdb())
# Register the data frame as a DuckDB table
duckdb::duckdb_register(con, out_table, dat_realtime_raw)

# we will just burn locally then sync
DBI::dbExecute(
  con,
  glue::glue("COPY {DBI::SQL(out_table)} TO '{out_file}' (FORMAT PARQUET)")
)

#Amalgamate Results-----------------------------------------------------------------------------------------------------
#load duckdb-----------------------------------------------------------------------------------------------------

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/water-temp-bc.duckdb", read_only = FALSE)
dat_existing <- DBI::dbReadTable(con, "realtime_raw")

# deal with the col type conflict issue
dat_realtime_prep <- ngr::ngr_tidy_type(dat_existing, dat_realtime_raw)

cols_dupe <- c("STATION_NUMBER", "Date", "Value", "Parameter")

# we have LOTS of dupes in our og dfs from ECCC
dupes_realtime <- dat_realtime_prep |>
  dplyr::filter(Parameter == 5) |>
  dplyr::group_by(dplyr::across(dplyr::all_of(cols_dupe))) |>
  dplyr::filter(dplyr::n() > 1) |>
  dplyr::ungroup()

# so remove
dat_realtime <- dat_realtime_prep |>
  dplyr::distinct(!!!rlang::syms(cols_dupe), .keep_all = TRUE)


# see duplicate rows where cols are shared.  Diffs in how cols are recorded means there are just a few
cols_common <- dplyr::intersect(names(dat_realtime), names(dat_existing))
dupes <- dplyr::intersect(
  dat_realtime |>
    dplyr::select(dplyr::all_of(cols_common)),
  dat_existing |>
    dplyr::select(dplyr::all_of(cols_common))
)

#see all dupe rows of the two dataframes considering select columns - values
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

# we had LOTS of dupes in our og dfs from ECCC but not anymore
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


# overwrite our amalgamated data to the database
DBI::dbWriteTable(con, "realtime_raw", dat_amalgamated, overwrite = TRUE)



#  we will just burn locally then sync to s3 with sync-data.R
# need to delete the old one first
fs::file_delete("data/realtime_raw.parquet")
DBI::dbExecute(con, "COPY realtime_raw TO 'data/realtime_raw.parquet' (FORMAT PARQUET)")
DBI::dbDisconnect(con)


# ishy <- paths[[130]]

# settings below are for future additions
# readwritesqlite::rws_write(dat, exists = F, delete = F,
#                            conn = conn, x_name = "temp_realtime")
# readwritesqlite::rws_disconnect(conn)

# this info was useful for the dat request so will leave here
# rt <- rws_read_table("temp_realtime", conn = conn)
# rt_head <- head(rt)
# cat(unique(rt$STATION_NUMBER))
# length((unique(rt$STATION_NUMBER)))
# min(rt$Date)
# max(rt$Date)



