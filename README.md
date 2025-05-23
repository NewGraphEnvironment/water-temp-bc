water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

The goal of `water-temp-bc` is to document and serve out water
temperature data.

<br>

<img src="fig/cover.JPG" width="100%" style="display: block; margin: auto;" />

<br>

Please see <http://www.newgraphenvironment.com/water-temp-bc> for
published table of collection links/details.

``` r
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
```

    ## [1] 0

``` r
tab <- DBI::dbGetQuery(con, "
  SELECT *
  FROM 's3://water-temp-bc/data/realtime-raw.parquet'
  WHERE STATION_NUMBER IN ('07EA004')
    AND Code = 'TW' 
    LIMIT 10
")
```
