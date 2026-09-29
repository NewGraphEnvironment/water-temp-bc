# Review round 2: staged diff for #19 (2026-09-29)

Scope: the staged versions of scripts/historic-functions.R, historic-test.R, historic-fold.R,
compact-functions.R, compact-test.R and compact.R. The working tree matches the index for all six.
Both suites were run from a copy of the staged files (`scratchpad/r2work/repo/`), and both passed
with 0 failures. All probes used anonymous S3 reads or scratch copies. The running dry run and its
work dir were read but not modified. The dry run finished while I was reviewing: exit 0, and its
p46 total of 101,763,401 matches my independent key count below.

## Findings

- **[fragile] scripts/compact-functions.R:118-130 (`shard_keys`)**: the key bound caps the
  **mean** keys per shard. What OOMs is the **largest** shard, and sharding by
  `hash(STATION_NUMBER) % n` over roughly 300 stations leaves the largest shard at about 2x the
  mean. I took per-station distinct keys for the post-fold p46/p47 from S3 (canonical ∪ 20240119 ∪
  20250521 ∪ 20250728). The p46 total was 101.8M, which agrees with the dry run. I then bucketed the
  stations with duckdb's own `hash()`:

  | case | shards | keys/shard mean | keys/shard max |
  |---|---|---|---|
  | 2026-09-13 runner run, p46 (passed) | 24 | 2.33M | 3.65M |
  | Jul-19 fix run, p47 (passed; keys estimated) | 20 | 2.29M | ~3.96M |
  | Jul-19 OOM run, p47 (keys estimated) | 12 | 3.82M | ~5.11M |
  | post-fold monthly, p46 | 51 | 2.00M | 3.97M |
  | post-fold monthly, p47 | 46 | 2.00M | 3.64M |

  The comment's argument ("2.3M keys per shard passed, so 2e6 has margin") compares means. At the
  worst shard, the post-fold store is not below anything the runner has passed. It sits at the
  passing edge. The worst shard also moves with the month's shard count, because each month
  re-buckets the stations. Over n_shards 44-62 the p46 max ranges from 3.25M to **4.80M** and the
  p47 max from 2.83M to 4.65M. Those upper values are near the ~5.1M estimated for the shard that
  OOM'd. The largest single station holds only 0.45M keys, so the skew comes from bucket
  collisions, not from one heavy station. That means a smaller `shard_keys` (for example 1e6, which
  costs extra scan passes only) or sizing shards on the heaviest bucket would restore the margin.
  Not a demonstrated failure: whether it OOMs depends on runner memory accounting. The planned
  post-publish `compact_only` dispatch checks only the month it runs; the next month's shard count
  can land on a worse bucketing.

- **[fragile, minor] scripts/historic-fold.R:55, 207, 224**: `WORK` defaults to
  `fs::path(tempdir(), "historic-fold")`. R deletes the session tempdir on exit, so a run without
  `HISTORIC_WORK_DIR` prints "would-be meta at <path>" for a file that no longer exists once the
  script ends. `historic-fold-report.csv` goes the same way. A publish that fails mid-way and says
  "re-run to finish" also discards the four downloaded originals, so the re-run downloads them
  again. The printed report still survives on stdout. No data is lost in the bucket.

## Checked, not flagged

- **Exclusion semantics.** Both sides are cast to `TIMESTAMP`, and all four originals have a naked
  `TIMESTAMP` Date, so the date comparison is an identity cast that ICU cannot shift. Parameter
  and Value are cast to DOUBLE on both sides, so eccc's string columns compare correctly. `IS NOT
  DISTINCT FROM` makes a NULL Value match a NULL Value. eccc has 6,000 NULL Values, and those
  copies are removed as intended. The exclusion reads the raw eccc/20240119 files, which are
  downloaded before 20250521 is normalized. `EXCLUDE[[f]]` is an exact `[[` lookup, so partial
  matching cannot fire.
- **Within-file duplicate keys, full files** (findings.md had sampled only 3 stations):
  - 20240119 and 20250728 have 0 duplicate keys.
  - eccc has 3,550 duplicate keys (7,100 rows), all on 2022-01-10/11.
    - Every one is identical in Value, Name_En, Symbol, Approval and Code.
    - The pairs differ only in `Quality`, which the projection drops.
  - So the tie in `compact_run()` is harmless. The comment at compact-functions.R:136-141 ("the
    one historic file that was not, 20250521") is inaccurate, but no behaviour depends on it.
- **harvested_at types**: canonical stores `harvested_at` as a naked `TIMESTAMP`, the same as the
  normalized files, so `UNION ALL BY NAME` does no TZ-sensitive cast. The dry run's values are
  strictly increasing and all before 2026-05-14.
- **compact_verify on a key-dense partition**: I checked this because it runs on an unconfigured
  in-memory connection. duckdb 1.5.2 in-memory uses `.tmp` for spill. A `SELECT DISTINCT` count of
  30M keys under `memory_limit = '300MB'` completed in 1.6 s, so the ~100M-key p46 verify on the
  runner is not at risk.
- **Monthly runtime after the fold**: the 2026-09-13 run did p46 in 24 passes over about 230M
  input rows in 3 min (about 7.5 s per pass). After the fold, p46 needs 51 passes over about 190M
  rows, roughly 6-7 min, and p47 is similar. That fits comfortably within `timeout-minutes: 180`,
  even with a 90-minute pull.
- **Meta**: jsonlite writes 212,198,908 and the per-partition counts as plain integers. The
  `historic_merged$files` array survives `read_json` and `write_json(auto_unbox = TRUE)`
  carry-forward in compact.R. The fold keeps `completed_at` unchanged, so `meta_unchanged()` still
  detects a concurrent compaction. The documented remedy (re-run the fold, then `compact_only`)
  recovers overwritten snapshot rows because the watermark is inclusive.
- **Publish ordering**: the harvested_at assertion runs before any upload, and the normalized
  source is synced before the partitions. `meta_unchanged()` runs before every partition sync and
  before the meta write. A partial publish leaves partitions that the next fold or monthly run
  dedups, and it never writes a meta that claims more than was folded.
- **compact.R bootstrap manifest**: it parses `aws s3 ls` names correctly, stops on a missing
  prefix (aws exit 1) or a missing file, and adds the historic dir to `raw_dirs`, not `todo`.
- **SQL construction**: every interpolated path goes through `sql_q`, so there is no injection
  path. No secrets are involved.
