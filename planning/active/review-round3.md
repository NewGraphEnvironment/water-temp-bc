# Code-check round 3: #27 staged diff (2026-09-12)

Scope: `git diff --cached` against main. I read in full every file listed in the task, both earlier review rounds, `findings.md` and the whole checklist. Every verdict below comes from something I ran, except where it says "re-read".

## Mechanism

**Each earlier defect was a claim that someone checked on the path they had in view, while a second path nobody ran also reached it.** The claims lived in a check, a comment, a step order, or a plan line. In each case the path that was checked stood in for a different one:

| The claim was checked against | But it was also reached by |
|---|---|
| the value the implementation returns | the harness's placeholder for a crashed case (`isTRUE(nzchar(NA))`) |
| the unfiltered `realtime_stations()` | the BC-filtered call that production makes |
| the fallback branch's `error` | the branch that succeeds live after a retry |
| credentials that are fresh when fetched | the same credentials 90 minutes later, when they are used |
| the full-pull event | `compact_only` and branch dispatches |
| one copy of a fact (the code comment) | its other copies (the plan text) |

The "two lists that happen to agree" are:
- the paths the author ran
- the paths that reach the claim

The two coincide on the happy path, so every check went green there. Another review round cannot close this class. What closes it is taking each claim, listing every path or copy that reaches it, and running each one.

Every place in this diff that the mechanism reaches:

| # | Claim, and where it lives | The second path | Verdict, and how it was checked |
|---|---|---|---|
| 1 | `run_case()`: "A case that errors must fail its checks" (`snapshot-test.R:42-52`) | The crash placeholder (`ids = NULL`, `error = NA`) run through every check | **Bites.** I swapped in an implementation that always calls `stop()`. Four checks PASS: T4 "NA not in ids", T6 "no NA", and both T8 checks. See Finding 1. |
| 2 | Restore-the-bug attribution (`progress.md:10`) | What actually made each T7 check fail against the stub | **Bites.** In `broken.out`, all 5 T7 FAILs come from the crash, not the NA id. See Finding 2. |
| 3 | The fixture's `REAL_TIME = NA` row is there to exercise `%in%` (`snapshot-test.R:71-75`, T7 at `:150`, `snapshot-functions.R:59`) | Vector subsetting followed by `clean()`, which is what the code actually does | **Bites (low).** With `==` restored the suite stays 31/31 green. See Finding 3. |
| 4 | `error` is NA on a first-try live result, and holds the last failure otherwise (`snapshot-functions.R:21-23`, test header) | All four return paths: live on the first try, live after a retry, fallback, and `stop()` | **Holds.** Read each path. T1, T2, T3 and T5 are green. The `stop()` message embeds a non-NA `err`. |
| 5 | `attempts` equals the number of calls made | Live (`attempt`) and fallback (`tries`) | **Holds.** Both are integer. The call count is asserted with `f$calls()`. |
| 6 | The final list is never empty | Live requires `length(live) > 0`. Fallback calls `stop()` when empty. | **Holds.** T8a passes. |
| 7 | A 404 gives zero rows, not an error. Stated in 4 copies: `snapshot-functions.R:14-16`, `snapshot-test.R:14-16,117,126`, `task_plan.md:17-18` | tidyhydat 1.0.1's own NA branch, run through `%in% prov` and `as.realtime()` | **Holds.** 0 rows, `character(0)`, no error. `as.realtime()` only sets a class and an attribute. |
| 8 | `retry_on_failure` defaults to FALSE, so tidyhydat never retries a failed connection. Stated in 2 copies: `snapshot-functions.R:11-13`, `snapshot-test.R:17-19` | httr2 1.3.0's own formals, and both of tidyhydat's `req_retry()` call sites | **Holds.** `formals(httr2::req_retry)$retry_on_failure` is `FALSE`. `realtime_parser()` and `tidyhydat_perform()` both call `req_retry(max_tries = …)` without setting it. |
| 9 | The annotations are one line each and never print NA (`snapshot.R:55-70`) | The fallback branch and the retried-live branch | **Holds.** Re-read, and round 2 agrees: every attempt on either branch sets `err`. |
| 10 | Probe placement and the AWS move, across all event shapes (`snapshot.yml:35-81`) | schedule, dispatch with `compact_only` false, dispatch with it true, and a branch dispatch | **Holds.** Re-read. The probe runs first and unconditionally. Round 2 traced all three event shapes. |
| 11 | Fixture types match production (`snapshot-test.R:71-75,83-84`, `progress.md:10`) | The real `tidyhydat::allstations` and the real xlsx | **Holds.** `allstations`: tibble; STATION_NUMBER and PROV_TERR_STATE_LOC character; REAL_TIME logical with 0 NA; 460 rows BC and REAL_TIME. xlsx `stationid`: character, 144 rows, 0 NA, 0 duplicates, 0 empty. |
| 12 | The bundled list lacks `08DA013` and `08DB015` (`snapshot.R:24-25`, `task_plan.md:45`) | `allstations` and the xlsx | **Holds.** Both ids are absent from both. Their being live rests on `findings.md`; I did not re-run that. |
| 13 | Data starts ageing out on 2028-02-02 (`task_plan.md:10`) | `date -d '2026-07-01 + 581 days'` | **Holds.** It prints 2028-02-02. |
| 14 | This is the first run of Pull + Upload + Compact together (`task_plan.md:47`) | `git log` on `snapshot.yml` | **Holds.** Compaction was wired in 2026-07-18 (`c4dcec3`), after the 07-01 pull. The 07-19 run was `compact_only`. The 08-01 and 09-01 runs died in Pull. |
| 15 | "Red at about 80 min with 0 chunks" means wateroffice is blocked, from about 462 × 10 s (`task_plan.md:48`) | `ngr_hyd_realtime` at `1e5758f`, and `tidyhydat::realtime_ws` | **Holds** for a block that drops packets. The secondary fetch runs only when the primary returns non-NULL, and errors are caught. So it is one `realtime_ws()` request per station, which is a single `req_perform()` with no retry: 462 × 10 s ≈ 77 min, under `timeout-minutes: 180`. A block that answers with a reset would fail fast instead, but the line does not claim to cover that case. |
| 16 | "31 assertions" (`progress.md:10`) | Running the real suite | **Holds.** 31 PASS, 0 FAIL, rc 0. |
| 17 | The first network call inside `realtime_stations()` | `has_internet()` | **No claim affected.** `has_internet()` probes `www.google.ca`, not ECCC. If it fails, it `stop()`s, which also goes through retry and then fallback. |

## Findings

No bugs or security issues in the production code (`snapshot-functions.R`, `snapshot.R`) or in the workflow. The three findings below are all in the test harness, a code comment, and a plan line.

- **[severity: fragile]** `scripts/snapshot-test.R:122` and `:139`: `!anyNA(r$ids)` passes on a crashed case.
  - `run_case()` returns `ids = NULL` for a crash, and `anyNA(NULL)` is FALSE.
  - Measured with an implementation that always calls `stop()`: T4 "NA not in ids" and T6 "no NA" both PASS.
  - This contradicts the harness's own comment at `:42` ("A case that errors must fail its checks"). It is round 1's defect (`isTRUE(nzchar(NA))`) again, on a second predicate.
  - The same file already guards its other NULL-sensitive checks: T7 uses `!is.null(r$ids) &&` and T6 "no duplicates" uses `length(r$ids) > 0 &&`. These two were missed.
  - There is no false green at suite level, because each of those sections has other checks that fail on a crash. But a restore-the-bug read per section would report a crashing T4 as 3/4 red, not 4/4.
  - Fix: `is.character(r$ids) && !anyNA(r$ids)` at both lines.
  - Related, but acceptable: both T8 `expect_error()` checks also pass on a crash (also visible in `broken.out`). The property T8 tests is "this errors", and the realistic regression (the guard removed) returns a value and goes red, which round 1 measured for the column guard. So T8 shows that the call errors, not that the named guard fired. It would need a message match to claim the latter.

- **[severity: fragile, planning]** `planning/active/progress.md:10`: "(plus T1/T6/T7 on the fixture's NA id)" gets the cause wrong for 5 of the 8 extra failures.
  - In the recorded stub run (`scratchpad/broken.R`, `broken.out`), T7's fetcher fails on every call and T7 passes no `eccc_ids`, so no NA reaches it.
  - All 5 T7 FAILs come from the stub letting the connect error propagate. That is the crash path.
  - Only T1 (1 FAIL) and T6 (2 FAIL) come from the NA id. The total of 24 is correct.
  - The line also leaves out that both T8 checks PASS against the stub.
  - Suggested wording: "plus T1/T6 on the fixture's NA id and T7 on the propagated connect error; T8 passes against the stub, since any error satisfies it."
  - This line lands in the Phase 1 commit, which carries the restore-the-bug record, so it is the version that stays in history.

- **[severity: fragile, low]** `scripts/snapshot-test.R:71-75` and `:150`, together with `scripts/snapshot-functions.R:59`: the fixture's `REAL_TIME = NA` row cannot detect the regression it is said to guard.
  - Both comments present the row as exercising `%in%` over `==` ("base `[` would keep an NA row as all-NA"; "%in% rather than == so NA … is excluded, not kept as an NA row").
  - The code subsets a vector, not rows. With `==`, `keep` is NA for that row, the subset yields `NA_character_`, and `clean()` on the same line drops it.
  - Measured: with `==` restored in a copy of the functions file, the suite is 31/31 green. T7 "REAL_TIME NA excluded" and "exactly the BC realtime rows" both PASS.
  - Behaviour is correct either way, because two mechanisms exclude NA. No production impact.
  - Only the stated reason is wrong: this arm cannot fail for the regression its comment names.
  - Fix: reword both comments to say NA is excluded by `%in%` and, independently, by `clean()`. Or, if the arm must discriminate, assert on `keep` directly.
