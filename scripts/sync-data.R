#Sync entire data dir to s3-----------------------------------------------------------------------------------------------------
processx::run(
  'aws',
  args = c(
    's3',
    'sync',
    'data',
    's3://water-temp-bc/data',
    # removes files that are not seen here locally
    '--delete')
  ,
  echo = TRUE,
  spinner = TRUE,
  timeout = 1200            # Timeout after 20 min
)


s3fs::s3_dir_ls("s3://water-temp-bc", recurse = TRUE)
s3fs::s3_dir_ls("s3://water-temp-bc/data", recurse = FALSE)
# s3fs::s3_dir_delete("s3://water-temp-bc/test")
