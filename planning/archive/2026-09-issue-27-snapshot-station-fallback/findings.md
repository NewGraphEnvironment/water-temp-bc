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
- On a 404, `realtime_parser()` returns `NA_character_` and `realtime_stations()` builds a single all-NA row (not an error). **Corrected in review:** with `prov_terr_state_loc = "BC"` that row is then subset away (`%in% prov`), so the production call returns **zero rows**. Either way the resolver must treat "no non-NA ids" as failure too (T5 is the production shape, T4 defensive).

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

## Implementation verification (2026-09-12, local)

- `Rscript scripts/snapshot-test.R` → 31/31 PASS, exit 0 (after the review fixes below).
- Restore-the-bug: same test against a one-shot `snapshot_stations()` mirroring the old `unique(c(realtime_stations(), eccc))` → 26 FAIL, exit 1 (final harness): T2–T5 each 4/4, T7 5/5, T8 2/2; T1 1 and T6 2 from the fixture's NA id. Against a stub that always `stop()`s: 31/31 FAIL.
  - The first version of this check reported "17 FAIL, every check in T2–T5 red". That was **false**: T3 "last error captured" and T5 "failure message recorded" both passed against the stub. `run_case()` put the crash message into `error`, and `isTRUE(nzchar(NA))` is TRUE. Caught by the plan review. Fixed with a separate `crashed` field and a `filled()` helper.
- Smoke, real data, exact `fetch_live` wrapper `snapshot.R` uses: live path `source=live attempts=1 n=446` (1.4 s); forced connect failure `source=fallback attempts=3 n=462`. 2 ids only in live (missing from the bundled table), 18 only in the fallback. Matches the plan-mode measurements.
- Probe step, extracted from the YAML and run under the runner's `bash --noprofile --norc -eo pipefail`:
  - real hosts: `dd.weather.gc.ca` HTTP 200 ip 205.189.10.47 connect 0.073 s tls 0.150 s; `wateroffice.ec.gc.ca` HTTP 200 ip 205.189.10.52 connect 0.073 s tls 0.192 s; exit 0
  - datamart swapped for unroutable `10.255.255.1`, 3 s timeout: `UNREACHABLE (curl exit 28)` with curl's own error on stderr, webservice probe still ran, exit 0
- YAML parses (R `yaml::read_yaml`). Step order: checkout → ECCC reachability → setup-r → deps → Pull snapshot → aws creds → Upload → Compact → Session info.
- `snapshot.R` annotations, evaluated from the file's own block: the fallback `::warning::` and the retry `::notice::` are each one line, with `%`/CR/LF escaped; nothing is printed on a first-try live success.

## Reviews

### Plan review (Plan agent, 2026-09-12)
Findings verified before acting:
- **Accepted and fixed:**
  - the restore-the-bug claim was false (above)
  - the 404 shape is zero rows, not an all-NA row: `realtime_stations("BC")` subsets with `%in% prov`, so the NA placeholder row drops. T5 is the production shape and T4 is defensive; comments corrected
  - a live answer after a retry lost the earlier error; it is now returned and logged as a `::notice::`
  - AWS credentials were fetched before a 40–90 min pull, and `configure-aws-credentials@v4` `role-duration-seconds` defaults to one hour (checked in its `action.yml`); credentials moved to after Pull
  - the probe was unreachable on `compact_only` or branch dispatches; moved to right after checkout, unconditional, `continue-on-error`
  - the probe now also logs `remote_ip` and `time_appconnect`
  - unused `library(dplyr)` removed from the test
- **Accepted as a known limitation, not changed:** a fallback run stays green and a `::warning::` sends no email. Confirmed that live `08DA013` and `08DB015` are missing from both the bundled table (absent from `allstations` entirely) and the xlsx. Decision: keep the run green, since a red run with the data already landed trains people to ignore red. The header comment now says plainly that a warning does not notify anyone. The Phase 4 follow-up covers a permanent station-list source if the datamart stays blocked.
- **Declined:** an id-format regex and a minimum-count floor on the live list. That is speculative for a truncated-body case nobody has seen, and a 403/5xx page already parses to zero BC rows and falls back (confirmed independently by review round 1).

### Code-check round 1 (2026-09-12)
Clean. Three notes, all already handled by the plan-review fixes or by the per-phase commit split: the 404-shape comment, planning files not matching staged code (the boxes are flipped per phase at commit), and the lost earlier error.

### Code-check round 2 (2026-09-12)
No defects in code or workflow. It traced all three event shapes after the AWS-credentials move, and the fallback path end to end at the pinned `ngr@1e5758f`. Two stale claims were found in planning notes: `progress.md` still carried the pre-fix "29 assertions / 17 FAIL" and the false restore-the-bug result, and `task_plan.md` T4 still called the all-NA row "the 404 shape". Both fixed.

The second is a defect **inside a previous fix**: correcting the 404 claim touched the code comments and missed the plan text. So the loop was ended by enumeration, not by a quiet round:
- I grepped every file in the review scope for `all-NA|404|placeholder` and for the old counts.
- All 404 statements now say zero rows in production, T4 defensive (`snapshot-functions.R:14-16`, `snapshot-test.R:15-16,117,126`, `task_plan.md:17-18`).
- No stale counts remain.
- The one further hit outside the review scope, this file's own plan-mode note at line 72, was corrected in place.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `gh run view --log-failed \| tail` showed only post-job cleanup | The error is mid-log; grep `gh run view --log` for `##[group]Run Rscript` with `-A` context |
| Error grep truncated by `head -40` before reaching the R step (apt noise first) | Filter apt lines out before `head`, or anchor on the step's `##[group]` line |
| `date -j -v+581d` → `invalid option -- 'j'` | `date` resolves to GNU coreutils on this machine; use `date -d '<date> + N days'` |
| `ModuleNotFoundError: No module named 'yaml'` extracting the workflow step in Python | No PyYAML on this machine; parse with R `yaml::read_yaml()` instead |

### Code-check round 3 (2026-09-12)
It named the mechanism behind every earlier defect. Each was a claim checked on the path its author had in view, while a second path nobody ran also reached it:
- the crash placeholder
- the BC-filtered call
- the live-after-retry branch
- credentials used 90 min after they were fetched
- `compact_only` dispatches
- the plan-text copy of a code comment

It walked 17 places the mechanism reaches. Three still bit, all in the test harness or notes, none in production code:
- **T4 "NA not in ids" and T6 "no NA" passed on a crash**, because `anyNA(NULL)` is FALSE. Both T8 `expect_error` checks also passed on any error. Fixed: an `is.character()` guard on both checks, and `expect_error(expr, pattern)` now matches the guard's own message.
- **`progress.md` attributed T7's stub failures to the NA id.** They come from the propagated connect error. Rewritten with measured per-section counts.
- **The `REAL_TIME = NA` fixture row was said to guard `%in%` over `==`.** `clean()` drops the NA either way; with `==` restored the suite stays green. The comments in the test and in `snapshot-functions.R` now say the row pins the outcome, not the mechanism.

**The loop was ended by enumeration, not by a fourth round.** All 31 checks were run against an implementation that always `stop()`s: **31/31 FAIL**, so no check can be satisfied by a crash.
- The real implementation: 31/31 PASS.
- The old one-shot behaviour: 26 FAIL (T2–T5 4/4 each, T7 5/5, T8 2/2, T1 1, T6 2).
- Agents used for this task: the Plan review plus 3 code-check rounds, 4 in all.

## Phase 4: runner validation (2026-09-13)

### Reachability from a GitHub runner

| run | ref | UTC | `dd.weather.gc.ca` | `wateroffice.ec.gc.ca` |
|---|---|---|---|---|
| 34734701063 | branch, `compact_only` | 03:07 | 200, connect 0.045 s, tls 0.073 s | 200, connect 0.041 s, tls 0.071 s |
| 34735036020 | `main`, full | 03:15 | 200, connect 0.042 s, tls 0.068 s | 200, connect 0.040 s, tls 0.071 s |

**Not a permanent block.** Both Aug and Sep failures hit ~12:00 UTC on the 1st, and these samples are ~03:10 UTC mid-month. So "intermittent" and "tied to that slot" are both still possible. The 2026-10-01 scheduled run is the next sample, and a repeat would now retry and fall back rather than kill the run.

### Full run on `main` (34735036020, 50 min, every step green)
- Station list: live on attempt 1, 446 stations. No `::warning::` or `::notice::` was raised.
- Pull: 03:19 → 03:59 (40 min). 90,878,878 rows, 292 distinct stations, 2025-02-09 → 2026-09-13 03:50. 154 stations returned "No data exists" (July: 156 of 448), and there were no other error kinds, so the webservice was healthy.
- Upload: `data/realtime/2026/09/snapshot_2026-09-13/`, 9 chunks, 10 s.
- Compact: 7 min. It merged `snapshot_2026-07-01` + `snapshot_2026-09-13`. Watermark → `snapshot_2026-09-13`; rows per parameter 5: 4,996,180; 6: 173,677; 46: 55,849,790; 47: 49,803,864; total 110,823,511 (bootstrap in #23 was 98,726,492).
- AWS credentials were fetched at 03:59 and used until 04:06, well inside the 1 h session. Before the move they would have been fetched at 03:19 and needed until 04:06 (47 min): inside the limit this time, but close enough to justify the move.
- Verified against S3 directly with no credentials: `canonical_meta.json` GET, and a list of the snapshot prefix. The anonymous list working also means the bucket's ListBucket policy gap noted in #23 has since been fixed.
- The Jul–Sep gap is filled: the snapshot reaches back to 2025-02-09.
