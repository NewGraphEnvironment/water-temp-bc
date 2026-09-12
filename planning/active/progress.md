# Progress — Monthly snapshot fails: runner cannot connect to dd.weather.gc.ca (realtime_stations) (#27)

## Session 2026-09-12

- Diagnosed from run logs 30699398871 (2026-08-01) and 33505653671 (2026-09-01): both die at `tidyhydat::realtime_stations()` on a 10 s TCP connect timeout to `dd.weather.gc.ca`. Issue #27 body rewritten with the diagnosis and proposed fix.
- Plan-mode exploration — phases approved by user
- Created branch `27-monthly-snapshot-fails-runner-cannot-con` off main
- Scaffolded PWF baseline from issue #27 with approved phases
- Next: start Phase 1 (`scripts/snapshot-test.R`)
- Phase 1: `scripts/snapshot-test.R` written — T1–T8, 31 assertions, plain-Rscript harness mirroring `compact-test.R`, exits 1 on failure. Restore-the-bug: run against a one-shot `snapshot_stations()` mirroring today's `unique(c(realtime_stations(), eccc))` → 26 FAIL, exit 1: T2–T5 each 4/4 red, T7 5/5 (the connect error propagates), T8 2/2 (`expect_error` matches the guard's message), T1 1 and T6 2 (the fixture's NA id survives). Against a stub that always `stop()`s: 31/31 FAIL — no check a crash can satisfy. The first run of this check, before the plan-review harness fixes, reported 17 FAIL and "every T2–T5 check red"; that was false (findings.md, Reviews). Fixture types checked against production: `allstations` is a tibble, STATION_NUMBER/PROV_TERR_STATE_LOC character, REAL_TIME logical with 0 NA; xlsx `stationid` character, 0 NA, 0 dup — the fixture's NA rows are defensive, not a production shape.
