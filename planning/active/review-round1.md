# Code review, round 1: staged diff for #27 (snapshot station fallback)

## Clean
I found no bugs, security problems, or data-loss risks in the staged code (`scripts/snapshot-functions.R`, `scripts/snapshot-test.R`, `scripts/snapshot.R`, `.github/workflows/snapshot.yml`).

### What was verified (measured, not reasoned)
- **The fallback actually helps.** `tidyhydat::realtime_ws()` (1.0.1), which `ngr::ngr_hyd_realtime()` calls, only contacts `wateroffice.ec.gc.ca`. None of its helpers (`ws_datetime`, `validate_params`, `tidyhydat_agent`) touch `dd.weather.gc.ca`. So once the station list comes from `allstations`, the pull no longer depends on the datamart.
- **`tidyhydat::allstations` resolves via `::`.** It is a tibble with STATION_NUMBER and PROV_TERR_STATE_LOC as character and REAL_TIME as logical. The BC & REAL_TIME filter gives 460 rows, which matches findings.md.
- **Non-404 HTTP errors are handled.** `realtime_parser()` sets `req_error(is_error = function(resp) FALSE)`, so a 403 or 5xx block page comes back as a body string and is parsed as CSV. The BC filter then leaves zero rows, which `snapshot_stations()` treats as a failure and falls back. The zero-length check is what makes this case safe.
- **The `::warning::` line is well-formed.** It escapes `%` before `\r`/`\n` (the correct order), and the title has no `:` or `,` that would need escaping as a property. `conditionMessage()` of an rlang/httr2 error under `GITHUB_ACTIONS=true` (cli 3.6.6) has no ANSI escapes. It is multi-line with a bullet, and the `%0A` escaping handles that.
- **The probe step cannot fail the job.** It runs under `-eo pipefail`, and `out=$(curl …) || rc=$?` protects the substitution. `date -u -d yesterday` is GNU and correct for ubuntu. The `if:` matches the sibling steps.
- **Tests pass:** `Rscript scripts/snapshot-test.R` gives 29/29, exit 0.
- **Restore-the-bug on the missing-column guard:** with lines 52–55 of `snapshot-functions.R` removed, T8's "bundled missing REAL_TIME column" check goes red (1 FAIL, exit 1). Without the guard, `bundled$REAL_TIME` is NULL, `%in%` returns `logical(0)`, and the run would silently use only the eccc ids. The guard and its test both work.

## Notes (not defects; for the author's judgement)
- **The "404 shape" comment is wrong for this call.** `scripts/snapshot-functions.R:14` and `scripts/snapshot-test.R:15` / T4 say the 404 shape is "a single all-NA row". That is true of `realtime_stations()` with no filter. With `prov_terr_state_loc = "BC"`, the NA row is subset away (`NA %in% "BC"` is FALSE), so the 404 result is **zero rows**. T5 covers zero rows and the code handles both shapes, so nothing breaks. Only the comment's claim about the production call is inaccurate.
- **The planning files don't match the staged code** (atomic-commit convention):
  - The staged `task_plan.md` flips only the Phase 1 boxes, but the same commit carries the Phase 2 code (`snapshot-functions.R`, the `snapshot.R` wiring) and the Phase 3 code (the probe step). All those boxes stay `[ ]`.
  - `progress.md` records Phase 1 only.
  - The findings.md "Implementation verification" section (smoke-test numbers 446/462, probe runs) is **unstaged**, so as staged the commit would not contain the verification record.
- **Minor gap against the plan:** Phase 2 says "log the source, attempt count, last error". When an attempt fails and a later one succeeds, `snapshot_stations()` returns `error = NA` and nothing is logged, so the first failure's message is lost and only "2 attempt(s)" survives. That count is enough to tell #27's transient-vs-block question. The probe step also records the detail. Mentioning it only because the plan promises more.
