# Ozone_Master_Sync.R
# Orchestrates: Data Fetching -> Model Training -> Forecasting

message("\n", paste(rep("=", 50), collapse = ""))
message(" STARTING GLOBAL OZONE ECOSYSTEM SYNC ")
message(paste(rep("=", 50), collapse = ""))

# 1. Sync Data
message("\n[1/3] Syncing Data for all sites...")
source("Ozone_Data_Manager.R")

# 2. Train Models
message("\n[2/3] Training Models for all sites...")
source("Ozone_Model_Training.R")

# 3. Generate Forecasts
message("\n[3/3] Generating Forecasts for all sites...")
source("Ozone_Forecaster.R")

message("\n", paste(rep("=", 50), collapse = ""))
message(" GLOBAL SYNC COMPLETE ")
message(paste(rep("=", 50), collapse = ""))
