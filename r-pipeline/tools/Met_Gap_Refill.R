# ---------------------------------------------------------------------------
# One-time repair: re-fetch ASOS weather for days saved with none.
#
# From late Sep 2026 the Iowa Environmental Mesonet rejected some requests
# (HTTP 429) and those days were saved with blank weather that nothing retried.
# The pipeline now repairs the last GAP_FILL_DAYS on every run; this reaches
# further back. It only writes the weather columns of days whose max_temp_f is
# NA -- O3 and every row that already has weather are left exactly as they are.
#
#   Rscript tools/Met_Gap_Refill.R              # since 2026-03-01
#   Rscript tools/Met_Gap_Refill.R 2026-09-01   # since a given date
#
# Same candidate-search pattern as Correct_AQM_Units.R.
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

args <- commandArgs(trailingOnly = TRUE)
since <- as.Date(if (length(args) > 0) args[1] else "2026-03-01")

source("Ozone_Data_Manager.R")  # loads sites_config.R and fill_met_gaps()

for (s in names(SITES_CONFIG)) {
  message("\n--- ", s, " ---")
  try(fill_met_gaps(s, since = since))
}
