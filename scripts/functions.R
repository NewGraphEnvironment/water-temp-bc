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
