# run_pipeline.R — Entry point for GitHub Actions
# Sets working directory to r-pipeline/ so all source() calls resolve correctly.

setwd(dirname(sys.frame(1)$ofile))

message("\n", paste(rep("=", 50), collapse = ""))
message(" STARTING OZONE PIPELINE (GitHub Actions)")
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
message("\n[4/4] Exporting JSON for dashboard...")
source("../export_json.R")

message("\n", paste(rep("=", 50), collapse = ""))
message(" PIPELINE COMPLETE ")
message(paste(rep("=", 50), collapse = ""))
