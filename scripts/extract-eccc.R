#Historic Data from ECCC-----------------------------------------------------------------------------------------------------
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
  dplyr::filter(Province == "BC")


# get the data just for the stations in BC
dat_eccc_raw2 <- dplyr::left_join(

  dat_eccc_raw |>
    ngr::ngr_tidy_type(stations_eccc),

  stations_eccc |>
    dplyr::select(StationName, StationID),

  by = "StationName"
)

# settings below are for future additions
readwritesqlite::rws_write(dat, exists = F, delete = F,
                           conn = conn, x_name = "temp_realtime")
readwritesqlite::rws_disconnect(conn)

# this info was useful for the dat request so will leave here
# rt <- rws_read_table("temp_realtime", conn = conn)
# rt_head <- head(rt)
# cat(unique(rt$STATION_NUMBER))
# length((unique(rt$STATION_NUMBER)))
# min(rt$Date)
# max(rt$Date)

