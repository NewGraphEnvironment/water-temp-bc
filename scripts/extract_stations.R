# Save the stations to the DB and parquet so we can see which stations are in a study area

#load duckdb-----------------------------------------------------------------------------------------------------

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/water-temp-bc.duckdb", read_only = FALSE)

DBI::dbListTables(con)

# get a list of the unique stationIDs
DBI::dbListFields(con, "realtime_raw")

stations_raw <- DBI::dbGetQuery(con, "SELECT DISTINCT STATION_NUMBER FROM realtime_raw")

# get the station locations from tidyhydat
stations_prep <- tidyhydat::allstations |>
  dplyr::filter(STATION_NUMBER %in% stations_raw$STATION_NUMBER)

# missing a station
stations_missing_allstations <- setdiff(stations_raw$STATION_NUMBER, t$STATION_NUMBER)

t2 <- tidyhydat::realtime_stations() |>
  dplyr::filter(STATION_NUMBER %in% stations_raw$STATION_NUMBER)

stations_missing_realtime <- setdiff(stations_raw$STATION_NUMBER, t2$STATION_NUMBER)

# get the missing station from realtime that is missing from allstations
station_add <- tidyhydat::realtime_stations() |>
  dplyr::filter(STATION_NUMBER %in% stations_missing_allstations)

# join them together
stations_prep2 <- dplyr::bind_rows(
  stations_prep,
  station_add
) |>
  sf::st_as_sf(coords = c("LONGITUDE", "LATITUDE"), crs = 4326, remove = FALSE) |>
  # get the timezones
  dplyr::mutate(tz = lutz::tz_lookup(geometry, method = "accurate"))


# 07FA008 wasn't there so we will fill it with the derived value
# this test that it is realtime data... yes
# test <- DBI::dbGetQuery(con, "SELECT * FROM realtime_raw WHERE STATION_NUMBER IN ('07FA008') AND PARAMETER IN (5)")
stations <- stations_prep2 |>
  dplyr::arrange(tz) |>
  tidyr::fill(HYD_STATUS:TIMEZONE, .direction = "down") |>
  dplyr::select(-TIMEZONE,-tz)

# check out the map
stations |>
  mapview::mapview()

# DuckDB needs geometry columns to be WKB (Well-Known Binary) format for spatial support
geom_wkb <- lapply(sf::st_geometry(stations), sf::st_as_binary)

stations_wkb <- stations |>
  sf::st_drop_geometry() |>
  dplyr::mutate(geometry = geom_wkb)

# burn to the database
# write our amalgamated data to the database
DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")
DBI::dbWriteTable(con, "stations_realtime", stations_wkb)

DBI::dbListTables(con)


# with the geometry column
# DBI::dbExecute(con, "COPY 'stations_realtime' TO 'data/stations_realtime.parquet' (FORMAT PARQUET)")

# burn all but the geometry column
cols <- grep("^geometry$", DBI::dbListFields(con, "stations_realtime"), invert = TRUE, value = TRUE) |>
  glue::glue_collapse(sep = ", ")

# burn locally too
query <- glue::glue("COPY (SELECT {cols} FROM stations_realtime) TO 'data/stations_realtime.parquet' (FORMAT PARQUET)")

DBI::dbExecute(con, query)



# here is how we can read it and turn to sf via the geom col but not really helpful
# t <- DBI::dbReadTable(con, "stations_realtime")
# sf::st_geometry(t) <- "geometry"
# # not sure wh
# sf::st_crs(t) <- 4326
#
# t |>
#   mapview::mapview()

