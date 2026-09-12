# Findings — Monthly snapshot fails: runner cannot connect to dd.weather.gc.ca (realtime_stations) (#27)

## Issue context

## Problem

The monthly realtime snapshot (`.github/workflows/snapshot.yml`) has failed on both scheduled runs since the last success:

| run | date | result |
|---|---|---|
| [28518844168](https://github.com/NewGraphEnvironment/water-temp-bc/actions/runs/28518844168) | 2026-07-01 | ✓ pulled 448 stations |
| [30699398871](https://github.com/NewGraphEnvironment/water-temp-bc/actions/runs/30699398871) | 2026-08-01 | ✗ Pull snapshot |
| [33505653671](https://github.com/NewGraphEnvironment/water-temp-bc/actions/runs/33505653671) | 2026-09-01 | ✗ Pull snapshot |

(The 2026-07-19 dispatch success was a `compact_only` run — the pull step was skipped, so it says nothing about ECCC reachability.)

Both failures are identical, 11 s into `scripts/snapshot.R`, at the very first network call:

```
Error in `httr2::req_perform()`:
! Timeout was reached [dd.weather.gc.ca]:
Failed to connect to dd.weather.gc.ca port 443 after 10002 ms: Timeout was reached
Backtrace:
 2. └─tidyhydat::realtime_stations(prov_terr_state_loc = "BC")
```

The script halts before any data is pulled, so upload and compaction are skipped.

## Cause: connection timeout to the datamart host, not a URL change

- **Not a URL change.** tidyhydat was 1.0.1 on the July success and both failures, and it already points at `https://dd.weather.gc.ca/today/hydrometric/`. The old `dd.weather.gc.ca/hydrometric/...` paths do now 404, but tidyhydat stopped using them before July.
- **Not a dead endpoint.** From a workstation on 2026-09-12 the same host returns `HTTP 200` for `today/hydrometric/doc/hydrometric_StationList.csv` in 0.4 s. It is a TCP *connect* timeout from the GitHub runner, not an HTTP error.
- **Transient outage vs persistent block of GitHub/Azure egress: not yet known.** Two consecutive months failing the same way at ~12:00 UTC on the 1st suggests a block, but does not prove one. Nothing in the current logs can tell them apart.
- **The station list is the only thing that needs the datamart.** The actual data comes from `ngr::ngr_hyd_realtime()` → `tidyhydat::realtime_ws()` → `wateroffice.ec.gc.ca`, which is a different host (verified returning real CSV from a workstation). However it sits on the same `/24` (`205.189.10.52` vs `.47` for `dd`), so if ECCC is blocking runner ranges at its edge, wateroffice may be blocked too.

## Data at risk

None yet. `DAYS_BACK = 581` (~19 months), so the next successful snapshot re-covers Aug–Sep, and the `data/canonical_meta.json` watermark in `compact.R` merges any missed months. The clock runs from the last successful pull (2026-07-01): data from then on starts ageing out of ECCC's realtime window on **2028-02-02** (2026-07-01 + 581 days). There's plenty of margin, but only if the pipeline recovers well before then.

## Proposed fix

1. **Diagnose on the runner.** Add a non-fatal pre-flight step to `snapshot.yml` that `curl`s both hosts with `--max-time` and logs connect time + HTTP code. That way every run records which host the runner could reach, and the transient-vs-block question answers itself.
2. **Stop the station list from being a single point of failure** in `scripts/snapshot.R`:
   - retry `realtime_stations()` a few times with backoff;
   - if it still fails, fall back to `tidyhydat::allstations` filtered to `PROV_TERR_STATE_LOC == "BC" & REAL_TIME`, unioned with the tracked `data/eccc/BC_Stations_withTW.xlsx`, and say so loudly in the log.

   Measured 2026-09-12: bundled `allstations` has 460 BC realtime stations vs 436 from the live list (2 live stations missing from the bundle, 26 bundled ones no longer live). With the xlsx that is 462 vs the 448 July pulled. Stations with no realtime data already fail softly (`No data exists for this station query`, caught by `possibly()`), so the extra ~14 cost a few calls, not a failure.
3. **Validate on the real runner.** The OIDC role trusts `main` only, so this has to be a `workflow_dispatch` after merge. Success criteria: pull step green, the preflight log shows both hosts' reachability, a `snapshot_<date>/` lands in S3, and compaction advances the watermark.

## Out of scope / follow-up

If the preflight shows `wateroffice.ec.gc.ca` is also unreachable from runners, the fallback in (2) will not help. The data host itself would then need a different egress (self-hosted runner, or a proxy), which becomes its own issue.

## Plan-mode exploration (2026-09-12)

### Where the 10 s comes from — curl, not httr2
- The R `curl` package hardcodes `CURLOPT_CONNECTTIMEOUT, 10L` (`jeroen/curl` `src/handle.c:158`). The failure text `after 10002 ms` is that limit.
- Runner package versions (from each run's session info):

  | run | date | result | curl | httr2 | tidyhydat |
  |---|---|---|---|---|---|
  | 28518844168 | 2026-07-01 | ✓ | 7.1.0 | 1.2.3 | 1.0.1 |
  | 30699398871 | 2026-08-01 | ✗ | 7.1.0 | 1.3.0 | 1.0.1 |
  | 33505653671 | 2026-09-01 | ✗ | 8.0.0 | 1.3.0 | 1.0.1 |

- July success and August failure share curl 7.1.0, so the 10 s limit was the same in both. httr2 1.2.3 → 1.3.0 correlates with the failures but its 1.3.0 NEWS is OAuth/cache only, and 1.3.0 connects locally in 0.4 s. **Coincidence, not cause.**
- So: from the GHA runner, `dd.weather.gc.ca` did not accept a TCP connection within 10 s. Slow vs blocked is not separable from the existing logs — Phase 3's 60 s-connect probe separates them.

### tidyhydat's retries never fire on a connection failure
- `tidyhydat:::realtime_parser()` sets `req_retry(max_tries = 3)`; `tidyhydat:::tidyhydat_perform()` re-sets `req_retry(max_tries = 5)`.
- httr2 `req_retry()` defaults `retry_on_failure = FALSE` — retries only transient HTTP statuses, never a failed connection. Hence one 10 s attempt and the step dead after ~11 s. Our own retry-on-error is not redundant.
- On a 404, `realtime_parser()` returns `NA_character_` and `realtime_stations()` returns a single all-NA row (not an error) — the resolver must treat "no non-NA ids" as failure too.

### Not a URL change
- tidyhydat 1.0.1 (all three runs) uses `base_url_datamart()` = `https://dd.weather.gc.ca/today/hydrometric/`. Old `dd.weather.gc.ca/hydrometric/...` paths now 404; `/today/...` returns 200 (station list 168,778 B in 0.44 s from a workstation, 2026-09-12).
- `ngr::ngr_hyd_realtime()` (0.0.1, pinned `@1e5758f`) only calls `tidyhydat::realtime_ws()` → `https://wateroffice.ec.gc.ca/services/real_time_data/csv/inline?` — returns real CSV from a workstation.
- DNS: `dd.weather.gc.ca` A `205.189.10.47`, `wateroffice.ec.gc.ca` A `205.189.10.52`, no AAAA, no CNAME. Same /24 — if ECCC blocks runner ranges at its edge, wateroffice may be blocked too.

### Fallback station source measured (2026-09-12, local)
- `tidyhydat::allstations` columns: STATION_NUMBER, STATION_NAME, PROV_TERR_STATE_LOC, HYD_STATUS, REAL_TIME, LATITUDE, LONGITUDE, station_tz, standard_offset, OlsonName.
- BC & REAL_TIME: **460**. Live `realtime_stations("BC")`: **436**. 2 live not in bundled; 26 bundled not live.
- `data/eccc/BC_Stations_withTW.xlsx` (tracked in git, `stationid` column): 144. Union with live: **446**; with bundled: **462**. July's run pulled 448.
- Non-live stations fail softly per station (`No data exists for this station query`, caught inside `ngr_hyd_realtime` and by `possibly()`), so the fallback's extra stations cost calls, not a failure.

### Run history
- Last pull success 2026-07-01 (42 min pull). 2026-07-19 dispatch success was `compact_only` — Pull + Upload skipped, so it says nothing about ECCC reachability.
- 581-day window: data from 2026-07-01 onward starts ageing out 2028-02-02 (`date -d '2026-07-01 + 581 days'`).

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `gh run view --log-failed \| tail` showed only post-job cleanup | The error is mid-log; grep `gh run view --log` for `##[group]Run Rscript` with `-A` context |
| Error grep truncated by `head -40` before reaching the R step (apt noise first) | Filter apt lines out before `head`, or anchor on the step's `##[group]` line |
| `date -j -v+581d` → `invalid option -- 'j'` | `date` resolves to GNU coreutils on this machine; use `date -d '<date> + N days'` |
