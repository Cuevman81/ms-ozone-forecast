# Ozone_Model_Training.R
# Trains site-specific Random Forest models for Ozone forecasting.

library(dplyr)
library(lubridate)
library(randomForest)
library(caret)
library(ggplot2)
library(tidyr)
library(readr)

# Load Site Configuration
source("sites_config.R")

# Function to train a model for a specific site
train_site_model <- function(site_name) {
  cfg <- SITES_CONFIG[[site_name]]
  if (is.null(cfg)) stop(paste("Site", site_name, "not found in config."))

  message(paste("\n--- Training Model for Site:", site_name, "---"))

  DATA_FILE <- cfg$data_file
  MODEL_FILE <- cfg$model_file

  if (!file.exists(DATA_FILE)) {
    message(paste("  Error: Data file", DATA_FILE, "not found. Skipping."))
    return(NULL)
  }

  # Smart Retrain: Skip if model is newer than data
  if (file.exists(MODEL_FILE)) {
    data_info <- file.info(DATA_FILE)
    model_info <- file.info(MODEL_FILE)
    if (model_info$mtime > data_info$mtime) {
      message("  Model is up to date with data file. Skipping retraining.")
      return(invisible(NULL))
    }
  }

  # --- 1. Load Data ---
  data <- read_csv(DATA_FILE, show_col_types = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    arrange(date)

  if (nrow(data) < 100) {
    message("  Warning: Not enough data rows for reliable training. Skipping.")
    return(NULL)
  }

  # --- 2. Feature Engineering ---
  message("  Generating features...")
  data <- data %>%
    mutate(
      O3_lag1 = lag(O3, 1),
      O3_lag2 = lag(O3, 2),
      max_temp_f_lag1 = lag(max_temp_f, 1),
      min_dewpoint_f_lag1 = lag(min_dewpoint_f, 1),
      ws_lag1 = lag(ws, 1),
      wd_lag1 = lag(wd, 1),
      O3_next = lead(O3, 1),
      max_temp_f_next = lead(max_temp_f, 1),
      min_dewpoint_f_next = lead(min_dewpoint_f, 1),
      ws_next = lead(ws, 1),
      wd_next = lead(wd, 1),
      doy = as.numeric(format(date, "%j")),
      is_weekend = as.numeric(weekdays(date) %in% c("Saturday", "Sunday")),
      td_spread = max_temp_f - min_dewpoint_f
    )

  # Define required features
  feature_cols <- c(
    "O3_next", "O3", "O3_lag1", "O3_lag2",
    "max_temp_f", "min_dewpoint_f", "ws", "wd",
    "max_temp_f_lag1", "min_dewpoint_f_lag1", "ws_lag1", "wd_lag1",
    "max_temp_f_next", "min_dewpoint_f_next", "ws_next", "wd_next",
    "doy", "is_weekend", "td_spread"
  )

  model_data <- data %>%
    select(all_of(feature_cols)) %>%
    drop_na()

  if (nrow(model_data) < 50) {
    message("  Warning: Not enough clean rows after NA removal. Skipping.")
    return(NULL)
  }

  message(paste("  Rows used for training:", nrow(model_data)))

  # --- 3. Train Model ---
  set.seed(42)
  train_idx <- createDataPartition(model_data$O3_next, p = 0.8, list = FALSE)
  train_set <- model_data[train_idx, ]
  test_set <- model_data[-train_idx, ]

  message("  Training Random Forest...")
  rf_model <- randomForest(O3_next ~ .,
    data = train_set,
    importance = TRUE,
    ntree = 200,
    nodesize = 10
  )

  # --- 4. Evaluation ---
  predictions <- predict(rf_model, newdata = test_set)
  rmse <- sqrt(mean((test_set$O3_next - predictions)^2))
  rsq <- 1 - sum((test_set$O3_next - predictions)^2) / sum((test_set$O3_next - mean(test_set$O3_next))^2)
  message(paste("  Model Stats: RMSE =", round(rmse, 4), "RSQ =", round(rsq, 4)))

  # --- 5. Strip training-time artifacts not needed for predict() ---
  # These can balloon the saved file from MB to ~GB on multi-thousand-row datasets.
  rf_model$predicted      <- NULL
  rf_model$y              <- NULL
  rf_model$oob.times      <- NULL
  rf_model$votes          <- NULL
  rf_model$localImportance <- NULL
  rf_model$inbag          <- NULL

  # --- 6. Save Model (xz compression typically 2-3x smaller than default gzip) ---
  saveRDS(rf_model, MODEL_FILE, compress = "xz")
  sz_mb <- round(file.info(MODEL_FILE)$size / 1024^2, 1)
  message(paste("  Model saved to:", MODEL_FILE, "(", sz_mb, "MB)"))
}

# Run for all sites only when this file is executed directly,
# not when sourced from app.R.
if (sys.nframe() == 0) {
  for (site in names(SITES_CONFIG)) {
    try(train_site_model(site))
  }
}
