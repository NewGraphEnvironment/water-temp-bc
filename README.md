water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

The goal of `water-temp-bc` is to document and serve out water
temperature data. Setup and wrangle scripts are located here
<https://github.com/NewGraphEnvironment/water-temp-bc> . Using
[`duckdb`](https://github.com/duckdb/duckdb-r) for `R` we are able to
connect directly to a parquet file stored on a S3 bucket and query
around to explore the provincial realtime data for the province of
British Columbia.

<br>

<img src="fig/cover.JPG" width="100%" style="display: block; margin: auto;" />

<br>

In the code chunks below we connect to duckdb load the `httpfs`
extension.

Please see <http://www.newgraphenvironment.com/water-temp-bc> for
published table of collection links/details.

``` r
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
```

\[1\] 0

<br>

In the next chunks we perform a couple of queries and present the
information about the data currently available.

``` r
tab <- DBI::dbGetQuery(
  con, 
  "SELECT *
  FROM 's3://water-temp-bc/data/stations_realtime.parquet'"
)
```

``` r
range <- DBI::dbGetQuery(con, "
  SELECT 
    STATION_NUMBER,
    MIN(Date) AS min_date,
    MAX(Date) AS max_date
  FROM 's3://water-temp-bc/data/realtime_raw.parquet'
  WHERE Code = 'TW'
  GROUP BY STATION_NUMBER;
")
```

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

Below we query for data from a particular site.

<br>
