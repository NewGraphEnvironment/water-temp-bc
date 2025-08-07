water-temp-bc
================

<!-- README.md is generated from README.Rmd. Please edit that file -->

![neeTo](https://img.shields.io/badge/status-neeTo-green)
![dEce](https://img.shields.io/badge/plays-dEce-red)

<img src="fig/cover.JPG" width="100%" style="display: block; margin: auto;" />

The goal of `water-temp-bc` is to document and serve out water
temperature data. Setup and wrangle scripts are located here
<https://github.com/NewGraphEnvironment/water-temp-bc> .

<br>

We scrape the Environment Canada (ECCC) web service for all realtime
temperature data for the province and serve it out from parquet files on
s3 storage. We are however limited to around 18 months of data or so -
so if we want current data we likely need to scrape on a schedule and
add the data to what we have. That said - ECCC has provided us with a
ton of historic data so in `scripts/extract-eccc.R` we wrangle that
together into one parquet file and serve on the cloud (s3 storage).

<br>

Currently we have more than 1 file so we we will need to put them all
together soon. TO DO. Here is a list of the files that we have currently
with the date stamp corresponding to the latest date for water
temperature data (there is also discharge and water level, air temp
mixed in for some sites.)

``` r
fs::dir_ls("data", glob = "*.parquet")
```

    ## data/realtime_raw_20240119.parquet      data/realtime_raw_20250728.parquet      data/realtime_raw_eccc_20221213.parquet 
    ## data/stations_realtime.parquet

<br>

Using [`duckdb`](https://github.com/duckdb/duckdb-r) for `R` we are able
to connect directly to the parquet files stored on a S3 bucket and query
around to explore the provincial realtime data for the province of
British Columbia. The beauty of
[`duckdb`](https://github.com/duckdb/duckdb-r) and the `parquet` file
format (provided we install the `httpfs` extension) is that we don’t
need a database. We just create a connection to a “virtual database”
with the line below and we can query the files directly in the s3
buckets…. Neeto.

    con <- DBI::dbConnect(duckdb::duckdb())
    DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")

<br>

Currently the [data directory of this
repo](https://github.com/NewGraphEnvironment/water-temp-bc/tree/main/data)
is mirrored at s3://water-temp-bc/data so punch in any of the urls below
into your browser and grab the files yourself.

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
  FROM 's3://water-temp-bc/data/realtime_raw_20250521.parquet'
  WHERE Parameter = '5'
  GROUP BY STATION_NUMBER;
")

# save local so need not run every time
saveRDS(range, "data/result.rds")
```

<br>

Below we query for data from a particular site. Note that Parameter =
‘5’ seems to be a better query than Code = “TW” since not all events are
currently labelled with a Code…

<br>

``` r
tab <- DBI::dbGetQuery(con, "
  SELECT *
  FROM 's3://water-temp-bc/data/realtime_raw_20250521.parquet'
  WHERE STATION_NUMBER IN ('07EA004')
    AND Parameter = '5' 
    LIMIT 100
")
```

``` r
DBI::dbDisconnect(conn = con)
```
