# run_pipeline.R — Entry point for GitHub Actions
# Sets working directory to r-pipeline/ so all source() calls resolve correctly.

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

# 1. Sync Data
message("\n[1/4] Syncing Data for all sites...")
source("Ozone_Data_Manager.R")

# 2. Train Models
message("\n[2/4] Training Models for all sites...")
source("Ozone_Model_Training.R")

# 3. Generate Forecasts
message("\n[3/4] Generating Forecasts for all sites...")
source("Ozone_Forecaster.R")

# 4. Export JSON for web dashboard
# Run as a separate Rscript process so it gets its own script path detection
message("\n[4/4] Exporting JSON for dashboard...")
export_script <- file.path(repo_root, "export_json.R")
exit_code <- system2("Rscript", args = export_script, stdout = "", stderr = "")
if (exit_code != 0) {
  stop("export_json.R failed with exit code ", exit_code)
}

message("\n", paste(rep("=", 50), collapse = ""))
message(" PIPELINE COMPLETE ")
message(paste(rep("=", 50), collapse = ""))
