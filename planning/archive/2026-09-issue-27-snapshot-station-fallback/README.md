## Outcome

**What failed.** The monthly snapshot died on 2026-08-01 and 2026-09-01 at `tidyhydat::realtime_stations()`, on a 10 s TCP connect timeout from the GitHub runner to `dd.weather.gc.ca`. That was the station-list call, before any data was pulled.
- It was not a URL change, and not a dead endpoint.
- tidyhydat's own retries never fire on a failed connection, so one timeout killed the run.

**What PR #29 changed:**
- the station list is retried, then falls back to the bundled `tidyhydat::allstations` plus the ECCC xlsx;
- a reachability check is now the workflow's first step;
- AWS credentials are fetched after the 40–90 min pull, not before.

**What we learned:**
- One post-merge run filled the Jul–Sep gap, because every pull re-covers a 581-day window.
- Both ECCC hosts were reachable from GitHub mid-month. Why the 1st-of-month runs failed is still open; the 2026-10-01 scheduled run is the next sample.

**Process.** The review loop caught my own false restore-the-bug claim: the test harness let a crashing implementation pass. It was closed by running every check against an always-crashing stub, rather than by more review rounds.

## Measurement

**The failure.**
- Both months failed with `Failed to connect to dd.weather.gc.ca port 443 after 10002 ms`. That is R curl's hardcoded `CONNECTTIMEOUT` of 10 s, not a server answer.
- Wrong turn kept for the record: httr2 went from 1.2.3 to 1.3.0 between the good and failed runs. That was a coincidence; curl, and so the 10 s limit, was identical in the July success.

**The station lists** (BC):

| source | stations |
|---|---|
| live `realtime_stations("BC")` | 436 |
| bundled `allstations`, `REAL_TIME` | 460 |
| live, unioned with the xlsx | 446 |
| bundled, unioned with the xlsx | 462 |

July's run pulled 448.

**The tests.**
- The final suite passes 31/31. The old behaviour fails 26 checks, and an always-crashing stub fails all 31.
- The first restore-the-bug report, "17 FAIL, every T2–T5 red", was false and has been corrected.

**Runner reachability on 2026-09-13.** Both hosts returned HTTP 200 with a connect of about 0.04 s, at 03:07 and 03:15 UTC.

**The full run on `main`** (34735036020, 50 min, green):
- live station list on the first attempt, 446 stations
- 90,878,878 rows from 292 stations, 2025-02-09 → 2026-09-13
- 154 stations returned no data (July: 156), with no other error kinds
- watermark moved from `snapshot_2026-07-01` to `snapshot_2026-09-13`
- canonical store now 110,823,511 rows (98,726,492 at the #23 bootstrap)
- verified from S3 directly, not only from the log

The durable facts are in `research/eccc-realtime-access.md`.

## Evidence

GitHub Actions runs of `snapshot.yml` (`gh run list --workflow snapshot.yml`):

| run | when | result |
|---|---|---|
| 28518844168 | Jul 1 | ✓ |
| 30699398871 | Aug 1 | ✗ |
| 33505653671 | Sep 1 | ✗ |
| 34734701063 | Sep 13 | branch run, reachability check only |
| 34735036020 | Sep 13 | `main`, ✓ |

The plan review and code-check triage are in `findings.md` (Reviews) and `review-round{1,2,3}.md`, in this directory.

Closed by: PR #29 (merge `05c21a3`), plus the wrap-up PR that adds this archive and closes #27.
