# export_json.R
# Reads existing CSV data and RDS models from the parent project
# and exports JSON files for the static web dashboard.
#
# Usage: Rscript export_json.R
#   (run from the web-dashboard/ directory, or from parent via: Rscript web-dashboard/export_json.R)

library(jsonlite)
library(readr)
library(dplyr)
library(randomForest)

# Resolve paths relative to the parent project
get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(dirname(sub("^--file=", "", file_arg))))
  }
  return(getwd())
}

script_dir <- get_script_dir()
parent_dir <- normalizePath(file.path(script_dir, ".."))
out_dir <- file.path(script_dir, "data")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# Load sites config
source(file.path(parent_dir, "sites_config.R"))

# --- Export sites_config as JSON ---
sites_json <- lapply(names(SITES_CONFIG), function(name) {
  cfg <- SITES_CONFIG[[name]]
  cfg$name <- name
  cfg
})
write_json(sites_json, file.path(out_dir, "sites_config.json"), pretty = TRUE, auto_unbox = TRUE)

# --- Export per-site data ---
for (site_name in names(SITES_CONFIG)) {
  cfg <- SITES_CONFIG[[site_name]]
  safe_name <- gsub(" ", "_", site_name)
  site_dir <- file.path(out_dir, safe_name)
  dir.create(site_dir, showWarnings = FALSE, recursive = TRUE)

  # 1. Historical training data (aq_MetDaily CSV)
  data_path <- file.path(parent_dir, cfg$data_file)
  if (file.exists(data_path)) {
    df <- read_csv(data_path, show_col_types = FALSE)

    # Recent 7 days for trend plot
    df$date <- as.Date(df$date)
    recent <- df %>% filter(date >= Sys.Date() - 6)
    write_json(recent, file.path(site_dir, "recent.json"), pretty = TRUE, na = "null")

    # Full data summary stats
    summary_info <- list(
      total_records = nrow(df),
      latest_date = as.character(max(df$date, na.rm = TRUE)),
      earliest_date = as.character(min(df$date, na.rm = TRUE)),
      completeness_pct = round(sum(!is.na(df$O3)) / nrow(df) * 100, 0),
      years_span = round(as.numeric(difftime(max(df$date, na.rm = TRUE),
                                              min(df$date, na.rm = TRUE),
                                              units = "days")) / 365, 1),
      days_behind = as.numeric(Sys.Date() - max(df$date, na.rm = TRUE)),
      last_5_rows = tail(df, 5)
    )
    write_json(summary_info, file.path(site_dir, "data_summary.json"), pretty = TRUE, auto_unbox = TRUE, na = "null")
  }

  # 2. Forecast history log
  hist_path <- file.path(parent_dir, paste0("history_", safe_name, ".csv"))
  if (file.exists(hist_path)) {
    hist_df <- read_csv(hist_path, show_col_types = FALSE)
    hist_df$Target_Date <- as.Date(hist_df$Target_Date)
    hist_df$Run_Date <- as.Date(hist_df$Run_Date)
    hist_df <- hist_df %>% arrange(desc(Target_Date))
    write_json(hist_df, file.path(site_dir, "history.json"), pretty = TRUE, na = "null")

    # Performance metrics
    calc_metrics <- function(full_data, threshold = NULL) {
      get_col_stats <- function(col_name) {
        sub_data <- if (!is.null(threshold)) {
          full_data %>% filter(!is.na(.data[[col_name]]) & !is.na(Observed_O3) & Observed_O3 >= threshold)
        } else {
          full_data %>% filter(!is.na(.data[[col_name]]) & !is.na(Observed_O3))
        }
        n <- nrow(sub_data)
        if (n < 1) return(list(n = 0, rmse = NA, bias = NA, mae = NA, r2 = NA))

        res <- list(
          n = n,
          rmse = round(sqrt(mean((sub_data$Observed_O3 - sub_data[[col_name]])^2)), 4),
          bias = round(mean(sub_data[[col_name]] - sub_data$Observed_O3), 4),
          mae = round(mean(abs(sub_data$Observed_O3 - sub_data[[col_name]])), 4),
          r2 = if (n >= 2) round(cor(sub_data$Observed_O3, sub_data[[col_name]])^2, 3) else NA
        )

        if (!is.null(threshold)) {
          eval_data <- full_data %>% filter(!is.na(.data[[col_name]]) & !is.na(Observed_O3))
          hits <- sum(eval_data$Observed_O3 >= threshold & eval_data[[col_name]] >= threshold, na.rm = TRUE)
          misses <- sum(eval_data$Observed_O3 >= threshold & eval_data[[col_name]] < threshold, na.rm = TRUE)
          fas <- sum(eval_data$Observed_O3 < threshold & eval_data[[col_name]] >= threshold, na.rm = TRUE)
          res$pod <- if ((hits + misses) > 0) round(hits / (hits + misses), 2) else NA
          res$far <- if ((hits + fas) > 0) round(fas / (hits + fas), 2) else NA
        }
        res
      }

      list(
        RF = get_col_stats("RF_Pred"),
        AQM_06R = get_col_stats("AQM_06_Reg"),
        AQM_06BC = get_col_stats("AQM_06_BC"),
        AQM_12R = get_col_stats("AQM_12_Reg"),
        AQM_12BC = get_col_stats("AQM_12_BC")
      )
    }

    metrics <- list(
      overall = calc_metrics(hist_df),
      moderate = calc_metrics(hist_df, threshold = 0.055),
      usg = calc_metrics(hist_df, threshold = 0.071)
    )
    write_json(metrics, file.path(site_dir, "metrics.json"), pretty = TRUE, auto_unbox = TRUE, na = "null")
  }

  # 3. Model variable importance
  model_path <- file.path(parent_dir, cfg$model_file)
  if (file.exists(model_path)) {
    model <- readRDS(model_path)
    imp <- as.data.frame(importance(model))
    imp$Feature <- rownames(imp)
    write_json(imp, file.path(site_dir, "importance.json"), pretty = TRUE, auto_unbox = TRUE, na = "null")
  }
}

# --- Export metadata ---
meta <- list(
  exported_at = as.character(Sys.time()),
  export_date = as.character(Sys.Date()),
  num_sites = length(SITES_CONFIG)
)
write_json(meta, file.path(out_dir, "meta.json"), pretty = TRUE, auto_unbox = TRUE)

message("Export complete. JSON files written to: ", out_dir)
