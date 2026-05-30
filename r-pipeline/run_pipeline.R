# run_pipeline.R — Entry point for GitHub Actions
# Sources each R script to load functions, then explicitly loops all sites.

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(dirname(sub("^--file=", "", file_arg))))
  }
  return(getwd())
}

pipeline_dir <- get_script_dir()
repo_root <- normalizePath(file.path(pipeline_dir, ".."))
setwd(pipeline_dir)

message("\n", paste(rep("=", 50), collapse = ""))
message(" STARTING OZONE PIPELINE (GitHub Actions)")
message(paste("  Pipeline dir: ", pipeline_dir))
message(paste("  Repo root:    ", repo_root))
message(paste(rep("=", 50), collapse = ""))

# Load site config
source("sites_config.R")

# 1. Sync Data — load functions then call for each site
message("\n[1/4] Syncing Data for all sites...")
source("Ozone_Data_Manager.R")
for (s in names(SITES_CONFIG)) {
  try(update_site_data(s))
}

# 2. Train Models
message("\n[2/4] Training Models for all sites...")
source("Ozone_Model_Training.R")
for (s in names(SITES_CONFIG)) {
  try(train_site_model(s))
}

# 3. Generate Forecasts
message("\n[3/4] Generating Forecasts for all sites...")
source("Ozone_Forecaster.R")
for (s in names(SITES_CONFIG)) {
  try(run_forecast(s))
}

# 4. Export JSON for web dashboard
message("\n[4/4] Exporting JSON for dashboard...")
export_script <- file.path(repo_root, "export_json.R")
exit_code <- system2("Rscript", args = export_script, stdout = "", stderr = "")
if (exit_code != 0) {
  stop("export_json.R failed with exit code ", exit_code)
}

message("\n", paste(rep("=", 50), collapse = ""))
message(" PIPELINE COMPLETE ")
message(paste(rep("=", 50), collapse = ""))
