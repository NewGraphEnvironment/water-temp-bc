my_tab_caption_rmd <- function(
    caption_text = my_caption,
    tip_flag = TRUE,
    tip_text = " <b>NOTE: To view all columns in the table - please click on one of the sort arrows within column headers before scrolling to the right.</b>") {

  cat(
    '<div style="text-align: center; font-weight: bold; margin-bottom: 10px;">',
    caption_text,
    if (tip_flag) tip_text,
    '</div>',
    sep = "\n"
  )
}

eccc_csv_extract <- function(path){

  d_head <- readr::read_csv(path, n_max = 2, col_names = F) |>
    dplyr::select(1:3) |>
    janitor::row_to_names(row_number = 1) |>
    purrr::set_names(c(
      "STATION_NUMBER",
      "Parameter",
      "Code")
    )

  d_body <- readr::read_csv(
    path,
    skip = 6,
    col_names = FALSE
  ) |>
    # col names false and this gets around corrupt files
    janitor::row_to_names(row_number = 1) |>
    # put the time in UTC
    dplyr::mutate(
      Time = lubridate::ymd_hms(Time, tz = "UTC")
    )

  d <- d_body |>
    dplyr::mutate(
      STATION_NUMBER = d_head$STATION_NUMBER,
      Parameter = d_head$Parameter,
      Code = d_head$Code
    ) |>
    dplyr::mutate(
      Name_En = dplyr::case_when(
        Parameter == "5" ~ "Water temperature",
        Parameter == "6" ~ "Discharge (daily mean)",
        T ~ NA_character_
      )) |>
    # rename Time to Date
    dplyr::rename(Date = Time)
  d
}

a <- eccc_csv_extract(path = "/Users/airvine/Projects/repo/water-temp-bc/data/eccc/QR_ProvisionalDailyValues_20151231_to_20221216/ts2_07EA005_20221216T150334.csv")

# this one is a problem - number stored as text?
path = "/Users/airvine/Projects/repo/water-temp-bc/data/eccc/QR_ProvisionalDailyValues_20151231_to_20221216/ts2_07EA005_20221216T150334.csv"
