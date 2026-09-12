# Task: Monthly snapshot fails: runner cannot connect to dd.weather.gc.ca (realtime_stations) (#27)

The monthly realtime snapshot (`.github/workflows/snapshot.yml`) failed on 2026-08-01 and 2026-09-01 — both identically, 11 s into `scripts/snapshot.R`, at the first network call:

```
tidyhydat::realtime_stations(prov_terr_state_loc = "BC")
Failed to connect to dd.weather.gc.ca port 443 after 10002 ms: Timeout was reached
```

The script halts before any data is pulled, so upload and compaction are skipped. The last pull success was 2026-07-01 (448 stations). No data lost yet — the 581-day window means data from 2026-07-01 onward starts ageing out on 2028-02-02. Fix: make the station list survive an unreachable datamart (retry + bundled fallback), and record per-run which ECCC host the runner can reach.

## Phase 1: Tests first
- [ ] `scripts/snapshot-test.R`: plain Rscript harness mirroring `compact-test.R`, with the contract for `snapshot_stations()` in the header. Cases:
  - T1: live OK → live ∪ eccc, `source == "live"`, 1 attempt
  - T2: error then success → live, 2 attempts
  - T3: error on every try → bundled BC `REAL_TIME` ∪ eccc, `source == "fallback"`, attempts == tries, error message captured
  - T4: tidyhydat 404 shape (one all-NA row) → fallback
  - T5: zero rows → fallback
  - T6: NA and duplicate ids dropped; output is character
  - T7: the bundled fixture includes non-BC and `REAL_TIME == FALSE` rows, so the fallback filter is actually exercised
  - Red by design until Phase 2
- [ ] Restore-the-bug check: against a one-shot `snapshot_stations()` that just calls `fetch_live()` (today's behaviour), T2–T5 must fail

## Phase 2: Station resolver
- [ ] `scripts/snapshot-functions.R`: `snapshot_stations()` as above: retry on error with a fixed `wait`, fall back to the bundled list, return ids + source + attempts + last error
- [ ] `scripts/snapshot.R`: source the functions file and replace the station block (lines 30–43). Log the source, attempt count, last error, and station count. Keep the existing xlsx-missing warning. Update the header comment.
- [ ] `snapshot-test.R` green
- [ ] Local smoke test of station resolution only (no 40-minute pull): real live path (expect ~446 with xlsx), and a forced-failure path (expect ~462)

## Phase 3: Runner diagnostics
- [ ] `snapshot.yml`: add an "ECCC reachability" step before Pull (skipped when `compact_only`)
  - `curl` the datamart station list (`dd.weather.gc.ca/today/hydrometric/doc/hydrometric_StationList.csv`) and a one-station `wateroffice.ec.gc.ca` realtime query
  - use `--connect-timeout 60 --max-time 90`, and print http_code, time_connect and time_total
  - it never fails the job: each probe reports "unreachable" instead of exiting, with stderr left visible
  - the 60 s connect timeout (vs curl R's hardcoded 10 s) is what separates "slow to connect" from "blocked"

## Phase 4: Validate on the real runner
- [ ] PR + merge (the OIDC role trusts `main` only, so validation must be post-merge)
- [ ] `gh workflow run snapshot.yml --ref main`; record the reachability numbers in `findings.md`
- [ ] Pull step green; the log shows which station source was used; `snapshot_<date>/` lands in S3; compaction advances the `canonical_meta.json` watermark
- [ ] Edit issue #27's body with the measured cause (blocked / slow / transient). If `wateroffice.ec.gc.ca` is unreachable from the runner, file a follow-up issue (different egress needed).

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
