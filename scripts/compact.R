#!/usr/bin/env Rscript
# scripts/compact.R
#
# Monthly canonical-store compaction orchestrator (#23). Runs on the GHA
# runner after the raw snapshot upload (or locally / via workflow_dispatch
# for bootstrap and repair). All S3 transfer lives here; the merge logic is
# in scripts/compact-functions.R, contract-tested by scripts/compact-test.R.
#
# Flow:
#   1. Read data/canonical_meta.json (the commit marker from the last
#      successful compact). Its last_merged snapshot date is the watermark;
#      no meta file => bootstrap over every raw snapshot.
#   2. Download raw snapshot dirs >= watermark (inclusive — idempotent).
#   3. Per Parameter (union of raw params + existing canonical partitions,
#      so a parameter absent from this month's pull is still preserved):
#      download that canonical partition, merge, verify invariants, sync the
#      partition back (--delete scoped to exactly that partition dir), then
#      free the local copies before the next pass — this bounds runner disk
#      no matter how large the store grows.
#   4. Only after every partition succeeds, upload the new meta. A failure
#      anywhere leaves the old meta in place, so the next run re-merges from
#      the previous watermark and self-heals.
#
# The pre-2024-10 record (#19) is not a raw snapshot: scripts/historic-fold.R
# merged it into canonical once, from data/historic/normalized/. A monthly
# run carries it forward inside canonical; a bootstrap (no meta, so no
# canonical to carry it) re-reads it from that prefix so a from-scratch
# rebuild cannot silently drop it.

suppressPackageStartupMessages({
  library(fs)
})
source("scripts/compact-functions.R")
source("scripts/historic-functions.R")  # HISTORIC_FILES

BUCKET       <- "s3://water-temp-bc"
RAW_PREFIX   <- "data/realtime"
CANON_PREFIX <- "data/canonical"
HIST_PREFIX  <- "data/historic/normalized"
META_KEY     <- "data/canonical_meta.json"
# ECCC has served 5, 6, 46 and 47 for BC stations since the realtime archive
# began; 1 (air temperature) and 18 (precipitation) come only from the
# folded-in 2022-06 -> 2024-01 historic pull (#19). Drift in either direction
# is worth a look but should not block the merge.
PARAMS_EXPECTED <- c(1L, 5L, 6L, 18L, 46L, 47L)

WORK <- Sys.getenv("COMPACT_WORK_DIR", unset = fs::path(tempdir(), "compact-work"))
MEMORY_LIMIT <- Sys.getenv("COMPACT_MEMORY_LIMIT", unset = "4GB")
fs::dir_create(WORK, recurse = TRUE)

aws <- function(...) {
  args <- c(...)
  out <- suppressWarnings(system2("aws", args, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop("aws ", paste(args, collapse = " "), " failed (exit ", status, "):\n",
         paste(out, collapse = "\n"))
  }
  out
}

# --- 1. Watermark from the last successful compact ---------------------------
# Another writer (historic-fold.R) holds canonical/ — checked here and again
# before every upload, so a fold that starts mid-run stops this one before
# it overwrites the fold's partitions.
stop_if_locked <- function() {
  if (canonical_lock_present(aws)) {
    stop(BUCKET, "/", CANONICAL_LOCK_KEY, " is present: another writer holds canonical/. ",
         "If no fold is running, it is stale — delete it and re-run.", call. = FALSE)
  }
}
stop_if_locked()

meta_local <- fs::path(WORK, "canonical_meta.json")
meta <- tryCatch({
  aws("s3", "cp", paste0(BUCKET, "/", META_KEY), meta_local, "--only-show-errors")
  jsonlite::read_json(meta_local)
}, error = function(e) {
  # Only a genuinely-absent meta means bootstrap; anything else (network,
  # auth) must fail loudly rather than silently degrade to a full re-merge.
  if (grepl("404|NoSuchKey|Not Found|does not exist", conditionMessage(e), ignore.case = TRUE)) NULL
  else stop(e)
})
# The meta as this run found it. Before every upload the live meta must still
# match byte for byte: historic-fold.R rewrites it (rows, historic_merged) but
# keeps completed_at, and a fold that ran start to finish while this run was
# merging would otherwise be erased by the next --delete sync below, with
# nothing afterwards to notice. (Absent at bootstrap: it must stay absent.)
meta_seen <- if (!is.null(meta)) readLines(meta_local, warn = FALSE) else NULL
stop_if_contended <- function() {
  stop_if_locked()
  now_local <- fs::path(WORK, "canonical_meta_now.json")
  if (fs::file_exists(now_local)) fs::file_delete(now_local)
  live <- if (canonical_lock_present(aws, key = META_KEY)) {
    aws("s3", "cp", paste0(BUCKET, "/", META_KEY), now_local, "--only-show-errors")
    readLines(now_local, warn = FALSE)
  } else NULL
  if (!identical(live, meta_seen)) {
    stop(BUCKET, "/", META_KEY, " changed while this run was merging; another writer ",
         "published to canonical/. Re-run to merge on top of it.", call. = FALSE)
  }
}

watermark <- if (!is.null(meta)) as.Date(sub("^snapshot_", "", meta$last_merged)) else NULL
message(if (is.null(meta)) "No canonical meta found — bootstrap over all raw snapshots."
        else paste0("Canonical watermark: ", meta$last_merged))

# --- 2. Which snapshots need merging ----------------------------------------
listing <- aws("s3", "ls", paste0(BUCKET, "/", RAW_PREFIX, "/"), "--recursive")
keys <- sub("^\\s*\\S+\\s+\\S+\\s+\\S+\\s+", "", listing)
snap_prefixes <- unique(sub("(/snapshot_[0-9]{4}-[0-9]{2}-[0-9]{2})/.*$", "\\1",
                            keys[grepl("/snapshot_[0-9]{4}-[0-9]{2}-[0-9]{2}/", keys)]))
todo <- compact_select_inputs(snap_prefixes, watermark)
if (length(todo) == 0) {
  message("Canonical is up to date — no snapshots at or past the watermark. Nothing to do.")
  quit(save = "no", status = 0)
}
message("Merging ", length(todo), " snapshot(s): ", paste(basename(todo), collapse = ", "))

raw_local <- fs::path(WORK, "raw")
raw_dirs <- character(0)
for (pfx in todo) {
  dest <- fs::path(raw_local, basename(pfx))
  aws("s3", "sync", paste0(BUCKET, "/", pfx), dest, "--only-show-errors")
  raw_dirs <- c(raw_dirs, dest)
}

historic_merged <- meta$historic_merged
if (is.null(meta)) {
  # Required, not optional: after the #19 fold, a bootstrap that ran without
  # it would publish a canonical missing everything before 2024-10, and the
  # row-count guard has no previous meta to catch that with. aws() stops on
  # a missing prefix as well as on a network failure.
  hist_listing <- aws("s3", "ls", paste0(BUCKET, "/", HIST_PREFIX, "/"))
  hist_files <- sub("^.*[[:space:]]", "", grep("[.]parquet$", hist_listing, value = TRUE))
  missing <- setdiff(HISTORIC_FILES, hist_files)
  if (length(missing) > 0) {
    stop("Bootstrap: ", HIST_PREFIX, " is missing ", paste(missing, collapse = ", "))
  }
  hist_local <- fs::path(WORK, "historic_normalized")
  aws("s3", "sync", paste0(BUCKET, "/", HIST_PREFIX), hist_local, "--only-show-errors")
  raw_dirs <- c(raw_dirs, hist_local)
  historic_merged <- list(files = hist_files, source = paste0(BUCKET, "/", HIST_PREFIX))
  message("Bootstrap: including the normalized historic record (", length(hist_files), " files).")
}

# --- 3. Parameters = raw params ∪ existing canonical partitions --------------
con <- DBI::dbConnect(duckdb::duckdb())
raw_globs <- sprintf("'%s'", sql_q(as.character(fs::path(raw_dirs, "*.parquet"))))
raw_params <- DBI::dbGetQuery(con, sprintf(
  "SELECT DISTINCT CAST(Parameter AS INTEGER) AS p
   FROM read_parquet([%s], union_by_name = true)
   WHERE Parameter IS NOT NULL ORDER BY p",
  paste(raw_globs, collapse = ", ")))$p
DBI::dbDisconnect(con, shutdown = TRUE)

canon_listing <- tryCatch(
  aws("s3", "ls", paste0(BUCKET, "/", CANON_PREFIX, "/")),
  error = function(e) character(0))
canon_params <- as.integer(sub(".*Parameter=([0-9]+)/.*", "\\1",
                               grep("PRE Parameter=[0-9]+/", canon_listing, value = TRUE)))
params_all <- sort(union(as.integer(raw_params), canon_params))

if (!setequal(params_all, PARAMS_EXPECTED)) {
  message("NOTE: parameter set {", paste(params_all, collapse = ", "),
          "} differs from the expected {", paste(PARAMS_EXPECTED, collapse = ", "),
          "} — proceeding, but worth investigating.")
}

# --- 4. Merge, verify, publish one partition at a time -----------------------
per_param <- list()
for (p in params_all) {
  message("Parameter ", p, ": merging...")
  canon_local <- fs::path(WORK, "canon")
  out_p       <- fs::path(WORK, sprintf("out_p%d", p))
  if (fs::dir_exists(canon_local)) fs::dir_delete(canon_local)

  have_canon <- p %in% canon_params
  if (have_canon) {
    aws("s3", "sync",
        paste0(BUCKET, "/", CANON_PREFIX, sprintf("/Parameter=%d", p)),
        fs::path(canon_local, sprintf("Parameter=%d", p)),
        "--only-show-errors")
  }

  res <- compact_run(
    raw_dirs, out_p,
    canonical_dir = if (have_canon) canon_local else NULL,
    params        = p,
    memory_limit  = MEMORY_LIMIT,
    temp_dir      = fs::path(WORK, "duckdb-tmp")
  )

  prev_p <- if (!is.null(meta)) as.numeric(meta$rows[[as.character(p)]]) else 0
  if (length(prev_p) == 0 || is.na(prev_p)) prev_p <- 0
  compact_verify(out_p, prev_rows = prev_p)

  stop_if_contended()
  aws("s3", "sync", "--delete",
      fs::path(out_p, sprintf("Parameter=%d", p)),
      paste0(BUCKET, "/", CANON_PREFIX, sprintf("/Parameter=%d/", p)),
      "--only-show-errors")

  per_param[[as.character(p)]] <- res$rows_written
  message("Parameter ", p, ": ", format(res$rows_written, big.mark = ","),
          " rows (", format(res$rows_in, big.mark = ","), " in, ",
          res$null_dropped, " NULL-key dropped)")

  if (fs::dir_exists(canon_local)) fs::dir_delete(canon_local)
  fs::dir_delete(out_p)
}

# --- 5. Commit marker --------------------------------------------------------
new_meta <- list(
  last_merged  = max(basename(todo)),
  rows         = per_param,
  total_rows   = sum(unlist(per_param)),
  completed_at = format(Sys.time(), tz = "UTC", "%Y-%m-%dT%H:%M:%SZ")
)
# Carried forward so the meta keeps saying canonical holds the historic fold.
if (!is.null(historic_merged)) new_meta$historic_merged <- historic_merged
jsonlite::write_json(new_meta, meta_local, auto_unbox = TRUE, pretty = TRUE)
stop_if_contended()
aws("s3", "cp", meta_local, paste0(BUCKET, "/", META_KEY), "--only-show-errors")

message(
  "Compaction complete: ", BUCKET, "/", CANON_PREFIX, "\n",
  "  snapshots merged: ", paste(basename(todo), collapse = ", "), "\n",
  "  partitions:       ", paste(sprintf("%s=%s", names(per_param),
                                format(unlist(per_param), big.mark = ",")), collapse = "  "), "\n",
  "  total rows:       ", format(new_meta$total_rows, big.mark = ","), "\n",
  "  watermark now:    ", new_meta$last_merged
)
