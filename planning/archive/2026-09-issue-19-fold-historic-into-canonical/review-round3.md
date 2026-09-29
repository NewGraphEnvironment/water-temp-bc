# Review round 3: staged diff for #19 (2026-09-29)

Scope: the staged diff (`scratchpad/diff-r3.patch`, confirmed byte-identical to `git diff --cached`
at review time). Both suites were run from a scratch copy of the staged files
(`scratchpad/r3work/repo/`), and both passed with 0 failures. The probes used anonymous S3 reads,
the frozen originals and normalized files under `scratchpad/fold/work/` (read-only), and the dry
run's `folded/` output (read-only). The running dry run was not touched. Probe scripts are in
`scratchpad/r3work/` (`p1.R`-`p7.R`, `st.R`, `sim.R`, `sim2.R`).

## Mechanism

A number measured on one population is carried to another as if it were a constant of the system.
r1 did this with an ordering: per-file harvest order was taken as per-row recency. r2 did it with a
bound: the mean keys per shard was taken as the max. The r2 fix repeats the pattern one level
down. It treats the **max/mean shard ratio (~2x)** as a constant, but that ratio was measured at
~50 shards (~6 stations per shard) and depends on how many stations share a bucket. The same shape
shows up as a guard that stands in for a property it covers only halfway:
`meta_unchanged()` compares `completed_at` to stand in for "no other writer touched canonical".

Every place in the diff where a count, ordering, bound or tiebreak stands in for a property,
checked against the real data:

| site | stands in for | verdict |
|---|---|---|
| `shard_keys = 1e6` + "1e6 puts the max near 2M" | largest shard ≤ what the runner survives | **wrong claim, see F1** |
| `meta_unchanged()` on `completed_at` | no concurrent writer to canonical | **covers half, see F2** |
| `harvested_at = max(Date)` per file | per-row recency on every shared key | holds, measured below |
| `exclude_matching` exact `(key, Value)` equality | "this row is a copy of an older one" | misses 52,297 float-ulp copies, harmless, measured below |
| "no duplicate key left" after exclusion | tiebreak never reached for 20250521 | holds: 82,027,048 rows = 82,027,048 keys |
| `Value DESC` tiebreak | the rows that tie are interchangeable | holds (eccc's 3,550 are identical, r2; 20250521 has none) |
| `(STATION_NUMBER, Date)` key for daily p6 | one row per station-day | holds: 0 station-days with two rows in folded p6 (550,275 at 08:00 plus 20,817 at 07:00) |
| `first_snapshot` literal 2026-05-14 | historic harvested_at < every canonical harvested_at | holds (max historic 2025-07-28) |
| `compact_verify(prev_rows)` | no rows lost | holds for the fold and monthly runs; bootstrap is prev = 0 by design |
| bootstrap `setdiff(HISTORIC_FILES, listing)` | the historic record is present | right direction (declared set present) |

## Findings

- **[fragile — the r2 fix's premise is wrong]** scripts/compact-functions.R:118-133. The comment
  says "1e6 puts the max near 2M". That assumes the max/mean ratio stays ~2x. It does not: halving
  `shard_keys` doubles the shard count and halves the stations per shard, from ~6 to ~3, so bucket
  collisions weigh more. I measured per-station distinct keys for the post-fold store (canonical
  ∪ the four normalized files; p46 total 101.76M, which matches the dry run's 101,763,401) and
  bucketed them with duckdb's own `hash(STATION_NUMBER) % n`:

  | | shards now | max shard now | max/mean over the next 30 months | max keys over the next 30 months |
  |---|---|---|---|---|
  | p46 | 102 | 2.79M | 2.51-3.60 (median 3.01) | 2.50-3.59M (median 3.00M; >3.0M in 15 of 31) |
  | p47 | 92 | 2.64M | 2.47-3.89 (median 2.97) | 2.47-3.88M (median 2.96M; >3.0M in 15 of 31) |

  ("Next 30 months" steps n from today's value by +1 per month, with every station's keys scaled
  so the mean stays at ~1M.) At 2e6, r2 measured a p46 range of 3.25-4.80M. So halving the bound
  cut the worst shard by about a quarter, not by half. Typical months land near 3M and the worst
  near 3.9M. That is about the largest the runner has passed (3.65M measured; ~3.96M estimated for
  p47) and about 1.3x from the ~5.1M that OOM'd, where the comment implies ~2.5x. This is not a
  demonstrated OOM. The margin is simply much thinner than the comment says, and it will be
  claimed again when someone next tunes the number.

  Cheaper and exact: size on the heaviest bucket rather than the mean. Either:
  - **bin-pack**: one `GROUP BY STATION_NUMBER` with an approximate distinct count, then assign
    stations to shards greedily (largest first). The max is then ≤ mean + the largest station
    (0.45M p46/p47, 0.95M p5).
  - **finer hash**: shard on `hash(STATION_NUMBER, year(Date))`. A key still never crosses shards,
    because year is a function of `Date`, and thousands of station-years make max/mean ≈ 1. The
    cost is that every part file then holds every station.

  The same stale number is in compact-test.R:13, which documents `shard_keys = 2e6` against the
  1e6 default.

- **[medium — data-loss path the guard's comment says it covers]** scripts/historic-fold.R:85-97,
  186, 222-232, together with scripts/compact.R:97, 167, 189. The comment says a compaction running
  during the fold is caught "before every upload … and before the meta write". The check compares
  only `completed_at`, which changes only when a compaction **finishes**. compact.R syncs each
  partition before it writes meta. So a compaction that is still running is invisible to the fold.
  The fold also deliberately keeps `completed_at` unchanged (`new_meta <- meta`), which makes the
  fold invisible to anything on the compaction side as well.

  The silent sequence goes like this:
  1. compact.R reads the pre-fold meta, so it has no `historic_merged` and pre-fold `rows`.
  2. It downloads canonical p.
  3. The fold syncs folded p.
  4. compact.R syncs p with `--delete`. This erases the historic rows and the fold's part files.
  5. The fold's last `meta_unchanged()` passes, because compact has not finished. The fold writes
     its meta and prints "Published."
  6. compact.R writes its meta. That meta has no `historic_merged`, and its `rows[p]` count lacks
     the historic rows.

  Nothing then fires. Future `compact_verify(prev_rows)` checks compare against compact's smaller
  count, and nothing records that the fold was undone. The mitigation today is prose only ("Do not
  run across the 1st"). `workflow_dispatch` can start a compaction at any time, and the fold takes
  minutes of wall time plus multi-GB uploads.

  Cheapest real fix: a lock object that both scripts take, for example
  `aws s3api put-object --key data/canonical.lock --if-none-match '*'`, released at the end. Short
  of that, compact.R should re-read the meta before its own meta write and refuse if it differs
  from what it started with. That at least turns the silent case into a loud one.

## Checked, not flagged

- **Harvest order = per-row recency (the r1 premise, re-tested on the fix's output).** Every
  normalized-20250521 row that shares a key with 20240119 (3.14M: p6 90, p46 1,061,321, p47
  2,079,699) is dated between 2023-10-18/21 and 2024-01-19. That is exactly the ~580-day window of
  a 2025-05-21 realtime pull (20250728's own window starts 2023-12-24). So every surviving
  "revision" came from the newer pull, not from the older sqlite amalgamated into the file, and it
  rightly outranks 20240119. There were 0 value ties within 1e-6.
- **Exclusion by exact float equality.** 52,297 eccc copies in 20250521 survive exclusion (p5
  3,425, p6 48,872), because eccc's strings parse to the next double: `"14.350000000000001"` vs
  `14.35`, max |Δ| 1.8e-12. They then outrank eccc's row. Measured harmless: Symbol, Approval and
  Code are identical on all 52,297 (including 631 non-NULL Symbols like ICE/ES/PX), and none of
  those keys exists in 20240119. The folded store keeps the cleaner double.
- **eccc vs 20240119** overlap on 517,020 p5 keys, with 0 value differences. 20240119 wins, so
  eccc's Approval `1` becomes `Provisional/Provisoire`. eccc code `1` covers every eccc row from
  2011 to 2022, including the final months, so this is not evidence of an approved→provisional
  downgrade. It falls under the accepted pass-through.
- **Re-fold "is a dedup no-op".** This holds while normalization is unchanged. A published fold
  cannot be corrected by re-folding under a changed normalization, because canonical's winners
  keep their source's harvested_at and still outrank older files. Moot unless a flawed fold is
  published.
- **Monthly runtime at 1e6.** p46 needs 102 passes and p47 92, over ~148M/132M input rows. Scaled
  from the 2026-09-13 run (~7.5 s per pass at 230M rows), that is about 8 and 7 minutes. It grows
  roughly with k², so it is fine under `timeout-minutes: 180` for years, but it is not free.
- **Staged suites:** historic-test.R and compact-test.R both report ALL TESTS PASSED from a copy
  of the index.
