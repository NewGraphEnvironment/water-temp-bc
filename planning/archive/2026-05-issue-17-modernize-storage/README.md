## Outcome

Modernized water-temp-bc storage + harvest. The bucket layout went from a flat set of dated `realtime_raw_*.parquet` files (hand-synced, ~9.5 months stale) to a Hive-partitioned `data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>.parquet` tree that a monthly OIDC-authenticated GitHub Actions cron keeps current. Each snapshot pulls the full ~18-month ECCC realtime window so QC corrections to older readings propagate automatically; a `harvested_at` column lets read-time dedup keep the most recently published value at each `(STATION_NUMBER, Parameter, Date)`. `scripts/query-helpers.R::query_canonical()` encapsulates that dedup so callers never see it, and `scripts/query.R` carries four worked examples. The pre-modernization parquets were preserved-as-is under `historic/` after we discovered their schemas were too heterogeneous to merge without a separate normalization pass.

Three things worth remembering for other repos:

1. **arrow's dplyr backend does not support grouped `slice_max`** — `arrow_not_supported("Slicing grouped data")`. The working pattern is `arrow::open_dataset(...) |> dplyr::filter(...) |> arrow::to_duckdb() |> dplyr::group_by(...) |> dplyr::slice_max(...) |> dplyr::ungroup()`. Generalizes to any "latest per group" query against parquet on S3.
2. **`as.POSIXct.Date(x, tz = "UTC")` silently ignores `tz =`** and converts using the system local zone. For users west of UTC this shifts the boundary by the local offset, silently dropping data near the edge. Always force UTC explicitly when accepting Date inputs: `as.POSIXct(format(x), tz = "UTC")`. Date `to` bounds should also widen to "< next-day-midnight" so the whole calendar day is included.
3. **Cross-prefix `arrow::open_dataset(unify_schemas = TRUE)` only works when types align.** A `Date` column with `tz=UTC` cannot be merged with a naked `timestamp[us]`; `Grade: string` cannot be merged with `Grade: double`. Discovered too late to normalize in scope; deferred to a separate follow-up. Generally: when migrating a dataset under a new schema, audit the schemas of any "historic" files BEFORE promising unified reads.

Closed by: PR NewGraphEnvironment/water-temp-bc#18 (squash commit 840b84f).

Cross-references:
- NewGraphEnvironment/rtj#147 — provisioned `modules/gha_s3_role/` Terraform module + `role_gha_water_temp_bc` IAM role (Phase 0 blocker).
- Outstanding follow-ups: historic schema normalization (body drafted at `/tmp/historic-normalize-issue.md`); incidental `data/water-temp-bc.duckdb` left in S3 from a past sync.
