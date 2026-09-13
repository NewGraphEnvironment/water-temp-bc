# Code-check round 2 — #27 staged diff (2026-09-12)

Scope: `git diff --cached` against main (snapshot-functions.R, snapshot-test.R,
snapshot.R, snapshot.yml, task_plan.md, progress.md). Read against the full
code-check checklist.

## Findings

No bugs in the code or the workflow. Two claims in the staged planning files
contradict the code:

- **[severity: fragile]** planning/active/progress.md:10 — the Phase 1 entry says
  "T1–T8, 29 assertions" and "17 FAIL, exit 1, every one of T2–T5 red". The
  staged `scripts/snapshot-test.R` has **31** checks (`Rscript
  scripts/snapshot-test.R | grep -c PASS:` → 31). The "every one of T2–T5 red"
  result is the one findings.md:93 records as **false**: under the old
  `run_case()`, T3 "last error captured" and T5 "failure message recorded"
  passed against the stub. The corrected numbers are 24 FAIL, with T2–T5 each
  4/4 red. Under the per-phase commit plan, this line lands in the Phase 1
  commit next to the current 31-check test. That commit's log would then state a
  count the file does not have and a restore-the-bug result that was wrong.
  Update the entry, or add a correcting line to the same entry, before that
  commit.

- **[severity: fragile]** planning/active/task_plan.md:17 — "T4: tidyhydat 404
  shape (one all-NA row) → fallback" contradicts the code:
  - snapshot-test.R names T4 "defensive; unfiltered 404 placeholder row" and T5
    "tidyhydat's 404 shape once filtered to BC"
  - snapshot-functions.R:14-16 says the same

  Confirmed against tidyhydat 1.0.1 (the runner's version).
  `realtime_stations()` returns `net_tibble[net_tibble$PROV_TERR_STATE_LOC %in%
  prov, ]`, so on a 404 the NA placeholder row is dropped and BC gets zero rows.
  findings.md says "comments corrected", but task_plan.md was not. It is a plan
  bullet, not behaviour, but it is the one place a reader goes for what each
  test covers.

## Verified, not findings

- **The fallback does unblock the pull.** `tidyhydat::realtime_ws()` (1.0.1)
  requests only `https://wateroffice.ec.gc.ca/...`. `ngr_hyd_realtime` at the
  pinned `ngr@1e5758f` (read from GitHub at that SHA, not the local 0.0.2) calls
  only `realtime_ws`. After the station list, nothing touches `dd.weather.gc.ca`.
- **Every failure shape of the live list reaches retry and fallback:**
  - `has_internet()` fails → `stop()`
  - connect timeout → error; httr2 does not retry it
  - 404 → zero BC rows
  - any other status: `realtime_parser()` sets `req_error(is_error = FALSE)`, so
    the error body is parsed as CSV, leaving zero BC rows
- **`tidyhydat::allstations` resolves via `::`** as a tibble:
  `STATION_NUMBER`/`PROV_TERR_STATE_LOC` character, `REAL_TIME` logical. 460
  rows are BC and `REAL_TIME`.
- **All three workflow event shapes work:**
  - schedule: `inputs.compact_only` is null, and `null != true`, so Pull runs
  - dispatch with `false`: Pull runs
  - dispatch with `true`: Pull is skipped. A skipped step does not make
    `success()` false, so AWS runs, Upload is skipped, and Compact runs.

  The AWS action exports its credentials through `GITHUB_ENV`, which reaches
  both Upload and `compact.R`'s `system2("aws")`. No step before the new AWS
  position uses AWS. A failed Pull still skips AWS, Upload and Compact, as
  before, and Session info still runs (`always()`).
- **Probe step:**
  - `local rc=0 out` is separate from `out=$(curl …) || rc=$?`, so it is safe
    under `-eo pipefail` and records curl's exit code
  - it contains no `${{ }}`, so there is no expression injection
  - the last command is the `if`/`echo`, so the step exits 0
  - `continue-on-error` keeps `success()` true either way
- **Annotations:**
  - `gha_escape()` escapes exactly what the spec requires for a message (`%`,
    CR, LF)
  - the literal titles contain no `:` or `,` needing property escaping
  - the runner splits on the first `::` after the properties, so a `::` inside
    the message is harmless
  - `st$error` is never NA on either branch that prints: fallback means every
    attempt set it, and retried-live means `attempts > 1`
- **Test harness:**
  - a crash now puts `error = NA`, so `filled()` is FALSE and every "error
    captured" check fails on a crashing implementation
  - `filled(NULL)` short-circuits on its length check
  - T1's `is.na(NULL)` gives NA, which `isTRUE` turns into a FAIL
  - 31/31 passing locally

planning/active/review-round2.md
