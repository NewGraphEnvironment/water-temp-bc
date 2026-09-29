source("scripts/compact-functions.R")
W <- commandArgs(TRUE)[1]
for (p in c(46L, 47L)) {
  t0 <- Sys.time()
  r <- compact_run(file.path(W, "snap"), file.path(W, sprintf("sim_p%d", p)),
                   canonical_dir = file.path(W, "folded"), params = p,
                   memory_limit = "4GB", threads = 2L, temp_dir = file.path(W, "sim-tmp"))
  compact_verify(file.path(W, sprintf("sim_p%d", p)), prev_rows = if (p == 46L) 101763401 else 91806298)
  n_files <- length(Sys.glob(file.path(W, sprintf("sim_p%d", p), "*", "*.parquet")))
  cat(sprintf("p%d: %s rows in -> %s written, %d shard files, %.0f s\n", p,
      format(r$rows_in, big.mark=","), format(r$rows_written, big.mark=","), n_files,
      as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  unlink(file.path(W, sprintf("sim_p%d", p)), recursive = TRUE)
}
