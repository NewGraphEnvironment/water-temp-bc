# ECCC realtime endpoints from GitHub Actions

> **Provenance:** measured 2026-09-12 and 2026-09-13 while fixing #27 (PR #29). Sources are run logs, package source at the versions named, and direct probes. Revise this file in place when new samples land; don't add a dated copy.

## Which hosts the snapshot touches

| host | what for | reached via |
|---|---|---|
| `dd.weather.gc.ca` (MSC Datamart) | BC station list, `today/hydrometric/doc/hydrometric_StationList.csv` | `tidyhydat::realtime_stations()` |
| `wateroffice.ec.gc.ca` | the data, `services/real_time_data/csv/inline?…` | `ngr::ngr_hyd_realtime()` → `tidyhydat::realtime_ws()` |

- Both hosts are on one `/24` (`205.189.10.47` / `.52`), with no AAAA record and no CNAME.
- The datamart moved under `/today/`, and the old `dd.weather.gc.ca/hydrometric/…` paths return 404. tidyhydat 1.0.1 already uses `/today/`.
- Nothing after the station list touches the datamart.

## Timeouts and retries (tidyhydat 1.0.1, httr2 1.3.0, curl 7.1–8.0)

- **The connect timeout is 10 s, hardcoded** in the R `curl` package (`CURLOPT_CONNECTTIMEOUT, 10L`, `jeroen/curl` `src/handle.c:158`). The error `Failed to connect … after 10002 ms` is that limit, not a server response.
- **tidyhydat's retries never fire on a failed connection.** `realtime_parser()` and `tidyhydat_perform()` call `httr2::req_retry(max_tries = …)` without `retry_on_failure`, which defaults to `FALSE`. That retries transient HTTP statuses only. `realtime_ws()` has no retry at all. A caller that needs resilience has to retry itself; `scripts/snapshot-functions.R` does.
- **A 404 is not an error.** `realtime_parser()` sets `req_error(is_error = FALSE)` and returns `NA` on 404. `realtime_stations("BC")` then returns **zero rows**, because its all-NA placeholder row is dropped by the province filter. Any other HTTP error body is parsed as CSV and also leaves zero BC rows. Treat "no ids" as failure.

## Offline station list

`tidyhydat::allstations` is bundled with the package and needs no network.

| source | BC stations |
|---|---|
| `allstations`, BC and `REAL_TIME` | 460 |
| live `realtime_stations("BC")` (2026-09-12) | 436 |
| union with `data/eccc/BC_Stations_withTW.xlsx` (144 ids), bundled | 462 |
| union with the xlsx, live | 446 |

- The bundled list is frozen at tidyhydat's build date. It already lacks live `08DA013` and `08DB015`, which are also absent from the xlsx.
- Roughly 155 stations in either union return `No data exists` per station, and fail softly. The count was 156 of 448 on 2026-07-01 and 154 of 446 on 2026-09-13.

## Reachability from GitHub-hosted runners

| date (UTC) | run | `dd.weather.gc.ca` | `wateroffice.ec.gc.ca` |
|---|---|---|---|
| 2026-07-01 12:54 | 28518844168 | ok (pull succeeded) | ok |
| 2026-08-01 12:21 | 30699398871 | **connect timeout, 10 s** | not reached |
| 2026-09-01 12:08 | 33505653671 | **connect timeout, 10 s** | not reached |
| 2026-09-13 03:07 | 34734701063 | 200, connect 0.045 s | 200, connect 0.041 s |
| 2026-09-13 03:15 | 34735036020 | 200, connect 0.042 s | 200, connect 0.040 s |

- **Not a permanent block.** Both failures were ~12:00 UTC on the 1st, so "intermittent" and "tied to that slot" are both still open.
- The workflow's "ECCC reachability" step logs a row like the ones above on every run. Its 60 s connect timeout separates *slow* from *blocked*. Add new samples here.
