# Review round 4: staged diff for #19 (2026-09-29)

Scope: the staged diff. `scratchpad/diff-r4.patch` is byte-identical to `git diff --cached` (checked
with `cmp` at review start). Six files are in scope: historic-functions.R, historic-test.R,
historic-fold.R, compact-functions.R, compact-test.R and compact.R. snapshot.yml is included for
context. Both suites were run from a copy of the index (`scratchpad/r4work/repo/`) and both printed
ALL TESTS PASSED, exit 0.

Probe scripts are in `scratchpad/r4work/p1.R`-`p7.R`. The probes read the following, and nothing
else:
- `fold/work/folded/` and `fold/work/historic_raw/`, read-only
- anonymous S3 reads (`--no-sign-request`)
- rtj's IAM module, at `~/Projects/repo/rtj/modules/gha_s3_role`

Nothing under `fold/` was written. Nothing was written to S3, and no lock object was created.

## Enumeration

Every constant, bound, threshold, ordering, tiebreak and guard that the diff introduces or relies
on, checked against the property it stands for.

| item | file:line | property it stands for | measured or assumed | holds on real data / covers the property fully? (evidence) |
|---|---|---|---|---|
| `shard_rows = 6e6` (pre-existing, now one of two load terms) | compact-functions.R:81, 178-180 | no single arg_max pass holds more rows than the runner survives | measured (runner run 29675228557) | **yes**. Keys now dominate the load: `sum(load)/n_shards` is 0.975-0.992 on p5, p46 and p47, so the rows term rarely binds (p5.R) |
| `shard_keys = 1.5e6` | compact-functions.R:82, 162-170 | the heaviest pass stays well under the 3.65M keys that last passed on the runner (OOM was at ~5.1M) | measured | **yes**. On the folded store the exact heaviest pass is p46 1.504M (72 passes), p47 1.496M (65) and p5 1.530M (12), all under 3.65M (p5.R). The comment's "68 passes / 1.59M" was measured on a different input, since the fold's input includes pre-dedup rows. The difference is immaterial |
| `approx_count_distinct(Date)` as per-station key load | compact-functions.R:171-177 | each station's distinct-key count | measured | **yes, with margin**. Per-station error is -14% to +30% for stations with 1e5-1e6 keys, and the sum is biased +5%, which gives more passes (the conservative direction). Even if every underestimated station landed in one pass, it would reach about 1.5M/0.86 ≈ 1.75M, still under 3.65M (p6.R) |
| LPT bound (Graham 4/3; heaviest ≤ mean + largest station) | compact-functions.R:52-72; compact-test.R:283 | the heaviest pass is bounded whatever the station count, unlike hash assignment | measured + theorem | **yes**. Heaviest/mean is 1.06 on p46 and p47; the largest station is 0.445M (p46/p47) and 0.953M (p5). The test's `4/3 * max(mean, max)` is a valid upper bound on LPT's worst case. Ties are deterministic: `which.min` takes the lowest index, and radix `order()` does not depend on locale |
| `''` as the sentinel for a NULL STATION_NUMBER in the shard filter | compact-functions.R:172, 185-192 | `''` never occurs as a real station number | measured | **yes on current data**: 0 NULL and 0 `''` station numbers in all four originals and in the folded store (canonical included) (p1.R). If a real `''` ever appeared, it would be filtered as `IS NULL` and silently dropped whenever a partition shards. Not reachable today |
| date floor `2002-01-01` | compact-functions.R:239 | admit the historic record, still catch epoch-0 / 2-digit-year dates | measured | **yes**. The minimum Date across the originals and the folded store is 2002-04-30 08:03 (p1.R) |
| `null_frac_max = 0.001` (pre-existing), denominator now includes canonical p and historic rows | compact-functions.R:80, 125-135 | a raw snapshot's NULL-key fraction is small | measured | **yes**. Historic files have 0 NULL Date/Parameter (p1.R), and the fold report shows `null_dropped` 0 on every partition. The monthly dilution by canonical p46 (~102M) is real, but p1 runs first against a 0.46M canonical, so the raw fraction is still gated before any upload |
| `harvested_at = max(Date)` per file, ordering eccc < 20240119 < 20250521 < 20250728 | historic-functions.R:110-113, 128; historic-fold.R:122-123 | per-row recency on every key two files share | measured | **yes**. The only 20250521 winners dated before its realtime window (2023-10-18) are exactly 3,425 p5 + 48,872 p6 rows. All are eccc float-ulp copies, with 0 diffs > 1e-9 against eccc. p46/p47 pre-window winners: 0. The 2.2M winners that overlap 20240119 are all dated 2023-10-21 → 2024-01-19 (p2.R; agrees with r3) |
| `first_snapshot = 2026-05-14` | historic-fold.R:124-127 | every historic harvested_at is before every canonical harvested_at | measured | **yes**. The earliest S3 snapshot is `snapshot_2026-05-14` (S3 listing). Canonical's min harvested_at is 2026-05-14 21:06:19 and the historic max is 2025-07-28 07:25 (p1.R) |
| exclusion join `(STATION_NUMBER, Parameter, Date, Value IS NOT DISTINCT FROM)` against eccc + 20240119 | historic-functions.R:132-144; historic-fold.R:51-52 | "this 20250521 row is a stale copy of an older row" | measured | **yes**. It misses only the 52,297 ulp copies, which are harmless (r3, re-confirmed above). No 20250521 row outside its window beats an older file with a different value |
| arg_max tiebreak `(harvested_at, coalesce(Value, -1e308))` | compact-functions.R:210-213 | rows that tie are interchangeable | measured | **yes**. Within-file ties exist only in eccc (3,550 keys, identical in kept columns, r2), 20250521 has no duplicate key after exclusion, and cross-file harvested_at values are strictly distinct |
| Unit map `HISTORIC_UNITS` | historic-functions.R:36-43, 101-108 | the Unit for each NULL-Unit row | measured | **yes**. The map equals the Parameter×Unit crosstab of both 20240119 and 20250728. The folded store has exactly one Unit per Parameter, with canonical and historic rows in the same group (same bytes), and 0 NULL (p1.R, p7.R) |
| Grade `-1` → NULL | historic-functions.R:115-121 | -1 is "no grade", never a grade | measured | **yes**. -1 occurs only in 20240119 (39,581,556 of 42.6M rows). 20250728 holds 10/20/NULL, 20250521 is all NULL, and the folded store holds 10/20/30/NULL (p7.R) |
| `HISTORIC_FILES` (fold source list, bootstrap manifest) | historic-functions.R:26-31; compact.R:114-119 | the historic record is complete and present | measured | **yes**. All four names are listed under `s3://…/data/historic/`. The bootstrap asserts the declared set is present, which is the right direction. The `s3 sync` also pulls any extra parquet, but none exist |
| `aws s3 sync …/Parameter=%d` download without a trailing slash | compact.R:160-163; historic-fold.R:182-185 | only partition p is downloaded (post-fold, `Parameter=1` is a string prefix of `Parameter=18`) | measured | **yes**. aws-cli 2.34 adds the directory slash: a dry run of `…/Parameter=4` lists 0 objects, although `Parameter=46/47` exist |
| `canonical_lock_present`: only `(404)`/`Not Found` means absent | compact-functions.R:41-50 | the lock object is absent | measured | **yes**. The live probe prints `An error occurred (404) … Not Found`. The runner role (rtj `gha_s3_role`) has `s3:ListBucket` on the bucket and `s3:GetObject` on `bucket/*`, so a missing key gives 404, not 403, on the runner too. A delete marker after release also HEADs as 404 (reasoned from S3 semantics, not measured) |
| `stop_if_locked()` at start, before each partition upload, before the meta write | compact.R:66-72, 178, 203 | compact.R never overwrites a fold's work | reasoned | **yes for a fold that is running.** Every upload is gated, and a fold started mid-run stops compact at its next check |
| `no_compaction_running()` status list `queued/in_progress/waiting/requested/pending` | historic-fold.R:148-156 | no compaction is in flight when the fold takes canonical | reasoned + gh | **half — see F2.** The list is complete against GitHub's run `status` enum (the other `--status` values are conclusions). It sees only snapshot.yml runs, while compact.R is also documented to run locally (compact.R:5-6), and compact.R never takes the lock itself |
| second `no_compaction_running()` after taking the lock | historic-fold.R:168 | detect a compaction that started between the first check and the lock | reasoned | **no — see F1.** It detects the compaction but stops while still holding the lock |
| `gh run list --limit 10` | historic-fold.R:149 | a live run is among those listed | measured | **yes**. The 10 most recent runs cover 2026-05-14 → 2026-09-13; a live run falling off the list needs 10 newer runs of one monthly workflow |
| lock `put-object` without `--if-none-match` | historic-fold.R:164-165 | no second fold takes the lock concurrently | assumed | holds by assumption: one operator, a one-time fold. Only compact.R is protected |
| `meta_unchanged()` on `completed_at` | historic-fold.R:88-97 | the meta the fold's counts rest on is still current | measured | **yes, as the belt it is described as**. The live meta has `completed_at`, so `identical(NULL, NULL)` cannot mask it. It catches a compaction that finished between step 0 (meta read, before the lock) and the lock |
| `prev_rows` (fold: `meta$rows[[p]]`; compact: carried meta rows) | historic-fold.R:195-197; compact.R:174-176 | no rows lost relative to current canonical | measured | **yes for the fold**: rows_after ≥ rows_before on all six partitions (fold report). It is a count proxy, blind to a loss smaller than the month's growth. That is pre-existing and relevant to F2 |
| `PARAMS_EXPECTED = {1,5,6,18,46,47}` | compact.R:45 | drift detection, message only | measured | yes: the folded partitions are exactly these six |
| `compact_verify` in-memory DISTINCT with no `memory_limit` | compact-functions.R:245-257 | the verify gate fits the runner | measured | **yes today**. Post-fold p46 (101.8M rows): 9.1 GB max RSS at 4 threads, 1.8-2.4 s. With a 3 GB limit it spills to `.tmp` and completes (4.8 s, 4.4 GB RSS) (p3.R, p4.R). This, not the 4 GB-capped arg_max, is now the process's memory peak. On a 16 GB runner, duckdb's default 80% limit (12.8 GB) is reached at about 140M p46 rows and degrades to spilling. Not a finding |
| `timeout-minutes: 180` / "~30 min" compaction estimate | snapshot.yml:28-32 | pull plus compaction fit the job | estimated | yes on r3's 7.5 s/pass scaling: p46 72 + p47 65 + p5 12 passes ≈ 20-25 min, plus a 40-90 min pull |
| JSON serialization of row counts | historic-fold.R:253; compact.R:202 | counts round-trip exactly | measured | yes: the dry-run meta has `101763401` and `212198908` verbatim |

## Findings

- **[low: the guard causes the failure it guards against]** scripts/historic-fold.R:162-168.
  The fold takes `data/canonical.lock` and then re-runs `no_compaction_running()`. If that second
  check finds a live snapshot.yml run, `stop()` exits while the lock is still held.

  The in-flight compaction the check just found then hits `stop_if_locked()` at its next
  partition upload (compact.R:178) and fails partway. The lock stays behind, so the next
  scheduled run also fails at compact.R:72 until someone deletes the lock by hand.

  The message the operator sees, "wait for it, then re-run the fold", is wrong on both counts:
  - the run will not finish, because of the fold's lock;
  - the re-run refuses at line 159-161 ("already exists — another writer holds canonical/").

  The same contradiction exists for a death mid-publish. The header (lines 27-29) says "re-run to
  finish", but the re-run refuses until the lock is deleted, and the lock message (lines 166-167)
  says to delete it only "once canonical is repaired (re-run the fold)", which is impossible in
  that order.

  No data is lost. Every step is loud, and the half-merged compaction self-heals from its old
  watermark. The cost is that the check's true branch kills a legitimate compaction and leaves a
  stale lock without saying so.

  Fix: on that path, delete the lock before stopping (the fold has touched nothing yet), and state
  the re-run procedure as "delete the lock, then re-run".

- **[low: the check covers GHA compactions only; one silent-loss path]** scripts/historic-fold.R:148-156
  and scripts/compact.R:5-6, 66-72, 178. `no_compaction_running()` stands in for "no compaction is
  in flight", but it sees only GHA runs of snapshot.yml. compact.R is documented to also run
  locally for bootstrap and repair, and it only *checks* the lock; it never takes it. The comment
  at compact-functions.R:31 ("take turns through one lock object") overstates this.

  The sequence, for a local compact.R:
  1. It downloads canonical p (compact.R:160) before the fold publishes p.
  2. Its merge of p is still running when the fold publishes p, writes meta and deletes the lock.
  3. Its `stop_if_locked()` at compact.R:178 sees no lock, and its `--delete` sync removes the
     fold's rows for p.
  4. Its meta write (built from the pre-fold meta read at start) drops `historic_merged` and
     records the smaller `rows[p]`.
  5. Every later `compact_verify(prev_rows)` compares against that smaller count, so nothing fires.

  This requires one partition merge to outlast the stretch from the fold's publish of p to its
  release. That stretch is minutes for p46 (72 passes), with p47 and the meta write behind it. The
  merge that must outlast it is several minutes on a slower machine, so the path is narrow but
  real.

  Fix, either:
  - compact.R takes the lock itself; or
  - before each upload and before the meta write, compact.R re-reads the live meta and stops if
    any field differs from what it started with. Compare the whole object, not `completed_at`:
    the fold deliberately keeps `completed_at` unchanged.

## Checked, not flagged

- Both staged suites pass from a copy of the index (compact-test.R, historic-test.R: 0 failures).
- The runner's IAM role is sufficient for every lock HEAD. Delete is scoped to `data/realtime/*`
  and `data/canonical/*`, which does not include `data/canonical.lock`. The runner never deletes
  the lock, so that is consistent.
- A GHA compaction that GitHub creates late (after the fold's checks) stops at compact.R:72. It
  stops after its raw upload, which the next watermark merge picks up.
- Canonical partitions in the kept `folded/` store contain 330-byte empty part files (p46 part-0,
  44 and 71; p47 part-18 and 86). They came from the hash-sharded code that produced that dry run
  (22:51-22:57), not from LPT, which never creates an empty pass. The content is unaffected, and a
  publish run regenerates the store.
