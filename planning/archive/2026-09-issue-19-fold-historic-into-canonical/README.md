## Outcome

The four pre-modernization files in `data/historic/` (2002 → 2025-07) had mismatched schemas and could not be read as one dataset. At the plan gate the approach changed from "rewrite them in place and add `include_historic`" to **fold them into `canonical/` once**, so `query_canonical()` returns the whole record unchanged.

- `historic_normalize()` projects each file onto the raw snapshot schema.
- `historic-fold.R` merges the four through the existing `compact_run()`/`compact_verify()`; it is a dry run by default.
- `compact.R` gained what a key-dense canonical needs: LPT station packing, a 2002 date floor, a bootstrap that re-reads `historic/normalized/`, and `data/canonical.lock` plus a live-meta guard on every upload.

The biggest lesson came from the data: 20250521 is an amalgamation carrying 52.0M metadata-stripped copies of older rows. Its later harvest date would have let those copies overwrite the originals, and its stale-vs-revised duplicate keys would have fallen through to a max-Value tiebreak. Excluding the copies on (key, Value) fixed both.

Review ran as a plan review plus four code-check rounds (review-*.md). Rounds 2, 3 and 4 each found a defect inside the previous fix:

- Round 2: the shard bound was reasoned from the mean shard, not the max.
- Round 3: the max/mean ratio had been treated as a constant; it was replaced by bin-packing. The same round found that a meta check cannot see an in-flight writer.
- Round 4: the lock's abort path, and local writers the `gh` check could not see.

The loop ended on round 4's 25-row enumeration of every constant and guard against real data, plus a writer-interleaving table (findings.md). The docs commit was self-reviewed rather than given a sixth reviewer; it is prose plus one `if (FALSE)` guard.

Also found: no store carries HYDAT-style B/E flags (only ECCC `ICE` etc., 2015-12 → 2022-12). That is corrected in the #19 body and flagged on wet#25. `sync-data.R --delete` was filed as #32. The settled facts are in [`research/historic-archive.md`](../../../research/historic-archive.md).

## Measurement

- **Time zone:** eccc ⋈ 20240119 p5 at zero offset gave 517,020 keys, 100% equal; at ±7/8 h, about 7% were equal. So the naked timestamps are UTC, and are stamped rather than shifted. 20250728 ⋈ canonical agreed the same way.
- **20250521:** 52,022,652 of its 134,049,700 rows are copies. Its 3,141,110 duplicate-key groups are each one copy plus one revision, and 0 remain after exclusion (82,027,048 rows).
- **Dry-run fold** (twice, identical; about 7 min locally): canonical goes from 110,823,511 to 212,198,908 rows.
  - p5: 4.99M → 17.29M, from 2002-04-30.
  - p6: 174K → 571K, from 2015-12-31.
  - p46: 55.8M → 101.8M. p47: 49.8M → 91.8M. Both from 2022-06-17.
  - p1 and p18 are new, frozen at 2022-06 → 2024-01.
  - Rows written equal an independent distinct-key count for every parameter. ICE rows: 807 of 807. p6 station-days with two rows: 0. The 196 files share one schema.
- **Shard packing on the post-fold store (p46):**

  | assignment | passes | heaviest pass |
  |---|---|---|
  | station hash, 2e6 | 51 | 3.97M keys (up to 4.80M) |
  | station hash, 1e6 | 102 | 2.79M keys |
  | LPT, 1.5e6 | 68 | 1.59M keys |

  For reference, the last run that passed on the runner had a heaviest pass of 3.65M keys, and the one that OOM'd about 5.1M. This moved the design from a tuned constant to packing.
- **Monthly re-merge simulation at 4 GB / 2 threads:** p46 126 s, p47 114 s, row counts unchanged. The runner itself is still unproven; that is the post-publish `compact_only` dispatch.

## Evidence

`data-raw/logs/historic_fold/20260929_*`: both dry runs, the runner-profile monthly simulation, and `scripts/historic-fold-check.R` run against the kept dry-run store (all pass) and against live S3 before the publish (fails as an unfolded store should; its per-parameter missing-key counts equal the dry run's added rows). They were committed in a follow-up PR after first being left in the session scratchpad.

## Post-merge (tracked in the #19 "Done when")

1. From `main`, clear of the 1st-of-month cron: `HISTORIC_FOLD_PUBLISH=1 Rscript scripts/historic-fold.R`, then `Rscript scripts/historic-fold-check.R s3://water-temp-bc/data/canonical s3://water-temp-bc/data/historic/normalized`.
2. Dispatch `snapshot.yml` with `compact_only=true` and watch memory and time on the runner.
3. Re-render `index.html` with `update_query = TRUE`.

Closed by: PR for branch `19-normalize-historic-schemas` (commits 0349bff, 154b981)
