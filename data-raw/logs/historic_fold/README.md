# historic_fold

Run logs for the one-time fold of the pre-2024-10 archive into `canonical/` ([#19](https://github.com/NewGraphEnvironment/water-temp-bc/issues/19)). `<work>` stands for the run's `HISTORIC_WORK_DIR`.

| file | what |
|---|---|
| `20260929_dryrun1.log` | First full dry run of `scripts/historic-fold.R` (outputs not kept) |
| `20260929_dryrun2.log` | Second dry run, after review round 2, with the store kept; identical counts |
| `20260929_check_dryrun.log` | `scripts/historic-fold-check.R` on that kept store, given the pre-fold meta: all pass, and snapshot-harvested rows equal the pre-fold canonical counts exactly |
| `20260929_check_s3_prefold.log` | The same check on live S3 before publishing: 7 failures, all where an unfolded store should fail. Its per-parameter "missing" counts equal the dry run's "added" |
| `20260929_monthly_sim.R` / `.log` | Next month's re-merge on the folded store at the runner profile (4 GB, 2 threads): p46 126 s, p47 114 s, counts unchanged |

The dry runs predate LPT shard packing (review round 3). Counts are unaffected; only pass sizes changed.
