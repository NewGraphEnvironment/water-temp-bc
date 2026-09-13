# Task: Monthly snapshot fails: runner cannot connect to dd.weather.gc.ca (realtime_stations) (#27)

The monthly realtime snapshot (`.github/workflows/snapshot.yml`) failed on 2026-08-01 and 2026-09-01 — both identically, 11 s into `scripts/snapshot.R`, at the first network call:

```
tidyhydat::realtime_stations(prov_terr_state_loc = "BC")
Failed to connect to dd.weather.gc.ca port 443 after 10002 ms: Timeout was reached
```

The script halts before any data is pulled, so upload and compaction are skipped. The last pull success was 2026-07-01 (448 stations). No data lost yet — the 581-day window means data from 2026-07-01 onward starts ageing out on 2028-02-02. Fix: make the station list survive an unreachable datamart (retry + bundled fallback), and record per-run which ECCC host the runner can reach.

## Phase 1: Tests first
- [x] `scripts/snapshot-test.R`: plain Rscript harness mirroring `compact-test.R`, with the contract for `snapshot_stations()` in the header. Cases:
  - T1: live OK → live ∪ eccc, `source == "live"`, 1 attempt
  - T2: error then success → live, 2 attempts
  - T3: error on every try → bundled BC `REAL_TIME` ∪ eccc, `source == "fallback"`, attempts == tries, error message captured
  - T4: all-NA ids → fallback (defensive: the unfiltered 404 placeholder row)
  - T5: zero rows → fallback (tidyhydat's 404 shape once filtered to BC)
  - T6: NA and duplicate ids dropped; output is character
  - T7: the bundled fixture includes non-BC and `REAL_TIME == FALSE` rows, so the fallback filter is actually exercised
  - Red by design until Phase 2
- [x] Restore-the-bug check: against a one-shot `snapshot_stations()` that just calls `fetch_live()` (today's behaviour), T2–T5 must fail

## Phase 2: Station resolver
- [x] `scripts/snapshot-functions.R`: `snapshot_stations()` as above: retry on error with a fixed `wait`, fall back to the bundled list, return ids + source + attempts + last error
- [x] `scripts/snapshot.R`: source the functions file and replace the station block (lines 30–43). Log the source, attempt count, last error, and station count. Keep the existing xlsx-missing warning. Update the header comment.
- [x] `snapshot-test.R` green
- [x] Local smoke test of station resolution only (no 40-minute pull): real live path (expect ~446 with xlsx), and a forced-failure path (expect ~462)

## Phase 3: Runner diagnostics
- [x] `snapshot.yml`: add an "ECCC reachability" step right after checkout, unconditional, so it also runs on `compact_only` and on branch dispatches (plan review moved it; it was first placed before Pull, behind `compact_only`)
  - `curl` the datamart station list (`dd.weather.gc.ca/today/hydrometric/doc/hydrometric_StationList.csv`) and a one-station `wateroffice.ec.gc.ca` realtime query
  - use `--connect-timeout 60 --max-time 90`, and print http_code, remote_ip, time_connect, time_appconnect and time_total (a connect that stalls in TLS points at a middlebox)
  - it never fails the job (`continue-on-error: true`, and each probe reports "unreachable" instead of exiting), with stderr left visible
  - the 60 s connect timeout (vs curl R's hardcoded 10 s) is what separates "slow to connect" from "blocked"
- [x] `snapshot.yml`: move `configure-aws-credentials` to after Pull (plan review). The pull needs no AWS and can take 40–90 min, and the action's default session is 1 h, so credentials fetched first could expire before Upload/Compact. A side effect: a branch dispatch now runs the probe and the full pull before stopping at the main-only OIDC trust, with no S3 writes

## Phase 4: Validate on the real runner
- [x] PR + merge (Upload and Compact need the OIDC role, which trusts `main` only). PR #29, merge `05c21a3`.
- [x] `gh workflow run snapshot.yml --ref main`; record the reachability numbers in `findings.md`. Run 34735036020, after branch run 34734701063.
- [x] Pull step green; the log shows which station source was used; `snapshot_<date>/` lands in S3; compaction advances the `canonical_meta.json` watermark. Live list on attempt 1, 446 stations; `snapshot_2026-09-13/` has 9 chunks; the watermark moved to `snapshot_2026-09-13` (110,823,511 rows).
- [x] Edit issue #27's body with the measured cause: blocked, slow, or "reachable on <date>". One probe can't show "transient"; the 2026-10-01 scheduled run is the second sample. Recorded as reachable on 2026-09-13: two runner samples, both hosts, ~0.04 s connect.
- [x] Follow-ups: none triggered. Both hosts were reachable, so neither a new egress nor a permanent station-list source is needed yet.
  - `wateroffice.ec.gc.ca` unreachable from the runner → a different egress is needed
  - `dd.weather.gc.ca` blocked but wateroffice fine → a permanent station-list source (the bundled list is frozen at tidyhydat's build and already lacks live `08DA013`, `08DB015`)
- Reading that run:
  - it is the first job ever to run Pull + Upload + Compact together, so a compaction failure is not necessarily #27
  - red at ~80 min with "0 chunks" means wateroffice is blocked (≈462 stations × the 10 s connect timeout)

## Validation

- [x] Tests pass
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
