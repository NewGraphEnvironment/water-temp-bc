water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

The goal of `water-temp-bc` is to document and serve out water
temperature data.

<br>

<br>

Please see <http://www.newgraphenvironment.com/water-temp-bc> for
published table of collection links/details.

``` r
tab <- DBI::dbGetQuery(con, "
  SELECT *
  FROM 's3://water-temp-bc/data/realtime_raw.parquet'
  WHERE STATION_NUMBER IN ('07EA004')
    AND Code = 'TW' 
    LIMIT 10
")
```

<br>

Here we grab the information about the stations (including locations and
date range available).

``` r
tab <- DBI::dbGetQuery(
  con, 
  "SELECT *
  FROM 's3://water-temp-bc/data/stations_realtime.parquet'"
)
```
