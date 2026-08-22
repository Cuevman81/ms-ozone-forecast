# ---------------------------------------------------------------------------
# This script lives in r-pipeline/tools/ but operates on the data files one
# level up, and its body uses bare filenames ("history_Hernando.csv"). Resolve
# the pipeline directory regardless of where R was started from, then work from
# there. Same candidate-search pattern as shiny-app/app.R.
# ---------------------------------------------------------------------------
PIPE <- local({
  candidates <- c("..", ".", "r-pipeline", file.path("web-dashboard", "r-pipeline"))
  hit <- Filter(function(d) file.exists(file.path(d, "sites_config.R")), candidates)
  if (length(hit) == 0) {
    stop("Cannot locate r-pipeline/ (no sites_config.R in: ",
         paste(candidates, collapse = ", "), "). Working directory is: ", getwd())
  }
  normalizePath(hit[1])
})
.old_wd <- getwd()
on.exit(setwd(.old_wd), add = TRUE)
setwd(PIPE)
message("Operating on: ", PIPE)

library(dplyr)
library(readr)

files <- c(
  "history_Gulfport.csv",
  "history_Hernando.csv",
  "history_Hinds_CC.csv",
  "history_Jackson_NCORE.csv",
  "history_Pascagoula.csv",
  "history_Waveland.csv"
)

aqm_cols <- c("AQM_06_Reg", "AQM_06_BC", "AQM_12_Reg", "AQM_12_BC")

for (f in files) {
  if (file.exists(f)) {
    message("Checking ", f, "...")
    df <- read_csv(f, show_col_types = FALSE)
    
    modified <- FALSE
    for (col in aqm_cols) {
      if (col %in% names(df)) {
        # Identify rows that are likely PPB (values > 1)
        ppb_idx <- which(!is.na(df[[col]]) & df[[col]] > 1)
        if (length(ppb_idx) > 0) {
          message("   Fixing ", length(ppb_idx), " rows in ", col)
          df[[col]][ppb_idx] <- df[[col]][ppb_idx] / 1000
          modified <- TRUE
        }
      }
    }
    
    if (modified) {
      write_csv(df, f)
      message("   Updated ", f)
    } else {
      message("   No changes needed for ", f)
    }
  }
}
message("Unit conversion complete.")
