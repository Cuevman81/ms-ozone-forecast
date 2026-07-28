# Ozone_Forecaster.R
# Uses AirNow API for real-time Ozone, NWS API for weather, and NOAA AQM for comparison.

library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(lubridate)
library(readr)
library(randomForest)
library(terra)

options(timeout = max(300, getOption("timeout")))

# Load Site Configuration
source("sites_config.R")

# --- Helper Functions (Shared with App) ---

# Fetch Latest Hourly Ozone from AirNow
get_latest_hourly_o3 <- function(aqs_id) {
  current_time_utc <- with_tz(Sys.time(), "UTC")
  clean_aqs <- gsub("-", "", aqs_id)

  for (offset in -1:6) {
    check_time <- current_time_utc - hours(offset)
    y_str <- format(check_time, "%Y")
    ymd_str <- format(check_time, "%Y%m%d")
    h_str <- format(check_time, "%H")

    url <- paste0(
      "https://s3-us-west-1.amazonaws.com/files.airnowtech.org/airnow/",
      y_str, "/", ymd_str, "/HourlyData_", ymd_str, h_str, ".dat"
    )

    tryCatch(
      {
        tf <- tempfile()
        suppressWarnings(download.file(url, tf, quiet = TRUE))
        if (file.info(tf)$size > 0) {
          df <- read_delim(tf, delim = "|", col_names = FALSE, show_col_types = FALSE)
          val_row <- df %>% filter(X3 == clean_aqs & X6 == "OZONE")
          if (nrow(val_row) > 0) {
            val_ppm <- as.numeric(val_row$X8[1]) / 1000
            unlink(tf)
            return(val_ppm)
          }
        }
        unlink(tf)
      },
      error = function(e) {
        if (exists("tf") && file.exists(tf)) unlink(tf)
      }
    )
  }
  return(NA)
}

# Fetch NWS Grid Forecast
get_nws_forecast <- function(lat, lon) {
  tryCatch(
    {
      # Use as.character to avoid any format() weirdness with numeric values
      pt_url <- paste0("https://api.weather.gov/points/", as.character(lat), ",", as.character(lon))
      point_res <- request(pt_url) %>%
        req_user_agent("MDEQ_OzoneApp") %>%
        req_perform() %>%
        resp_body_json()

      grid_res <- request(point_res$properties$forecastGridData) %>%
        req_user_agent("MDEQ_OzoneApp") %>%
        req_perform() %>%
        resp_body_json()

      parse_series <- function(series) {
        if (is.null(series) || is.null(series$values) || length(series$values) == 0) {
          return(NULL)
        }
        df_list <- lapply(series$values, function(item) {
          dt_str <- strsplit(item$validTime, "/")[[1]][1]
          dt <- ymd_hms(dt_str, quiet = TRUE)
          if (is.na(dt)) {
            return(NULL)
          }
          data.frame(datetime = dt, value = as.numeric(item$value))
        })
        do.call(rbind, df_list)
      }

      target_date <- Sys.Date() + days(1)

      # Extract Variables with safe filter
      safe_day_val <- function(df, target, func, fallback = NA) {
        if (is.null(df) || nrow(df) == 0) {
          return(fallback)
        }
        day_df <- df[as.Date(df$datetime) == as.Date(target), ]
        if (nrow(day_df) == 0) {
          return(fallback)
        }
        res <- func(day_df$value, na.rm = TRUE)
        if (is.infinite(res)) {
          return(fallback)
        }
        return(res)
      }

      df_temp <- parse_series(grid_res$properties$maxTemperature)
      max_t <- safe_day_val(df_temp, target_date, max)

      df_ws <- parse_series(grid_res$properties$windSpeed)
      avg_ws <- safe_day_val(df_ws, target_date, mean)

      df_dp <- parse_series(grid_res$properties$dewpoint)
      min_dp <- safe_day_val(df_dp, target_date, min)

      df_wd <- parse_series(grid_res$properties$windDirection)
      avg_wd <- safe_day_val(df_wd, target_date, mean)

      return(list(
        max_temp_f = (max_t * 9 / 5) + 32, ws = avg_ws * 0.539957,
        wd = avg_wd, min_dewpoint_f = (min_dp * 9 / 5) + 32
      ))
    },
    error = function(e) {
      message("  NWS API Error: ", e$message)
      list(max_temp_f = NA, ws = NA, wd = NA, min_dewpoint_f = NA)
    }
  )
}

# Fetch NOAA AQM Forecast
get_aqm_forecast <- function(lat, lon, target_date, cycle, is_bc) {
  run_dates <- c(as.Date(target_date), as.Date(target_date) - 1, as.Date(target_date) - 2)
  for (r_date in run_dates) {
    run_str <- format(as.Date(r_date), "%Y%m%d")
    type_str <- if (is_bc) "max_8hr_o3_bc" else "max_8hr_o3"
    # Try NOMADS first (faster dissemination), then S3 fallback
    urls <- c(
      paste0("https://nomads.ncep.noaa.gov/pub/data/nccf/com/aqm/prod/aqm.", run_str, "/", cycle, "/",
             "aqm.t", cycle, "z.", type_str, ".227.grib2"),
      paste0("https://noaa-nws-naqfc-pds.s3.amazonaws.com/AQMv7/CS/", run_str, "/", cycle, "/",
             "aqm.t", cycle, "z.", type_str, ".", run_str, ".227.grib2")
    )
    for (url in urls) {
      tf <- tempfile(fileext = ".grib2")
      tryCatch(
        {
          message(paste("    [DEBUG] Checking URL:", url))
          suppressWarnings(download.file(url, tf, mode = "wb", quiet = TRUE))
          sz <- file.info(tf)$size
          message(paste("    [DEBUG] Size:", sz))
          if (sz > 1000) {
            r <- rast(tf)
            t_str <- format(time(r), "%Y-%m-%d", tz = "UTC")
            idx <- which(t_str == as.character(target_date))
            message(paste("    [DEBUG] Target:", target_date, "Matched time slots:", length(idx)))
            if (length(idx) > 0) {
              pts <- vect(cbind(as.numeric(lon), as.numeric(lat)), crs = "EPSG:4326")
              val <- terra::extract(r[[idx[1]]], pts)[1, 2]
              message(paste("    [DEBUG] Extracted Val:", val))
              if (!is.na(val) && val > 1) val <- val / 1000
              unlink(tf)
              return(list(val = val, date = r_date))
            }
          }
          unlink(tf)
        },
        error = function(e) {
          message(paste("    [DEBUG] Error occurred:", e$message))
          if (exists("tf") && file.exists(tf)) unlink(tf)
        }
      )
    }
  }
  return(list(val = NA, date = NA))
}

# --- Core Forecasting Logic ---

run_forecast <- function(site_name) {
  cfg <- SITES_CONFIG[[site_name]]
  if (is.null(cfg)) stop(paste("Site", site_name, "not found."))

  message(paste("\n--- Running Forecast for:", site_name, "---"))

  # 1. Load Model and Data
  if (!file.exists(cfg$model_file)) {
    message("  Error: Model file not found. Skipping.")
    return(NULL)
  }


  rf_model <- readRDS(cfg$model_file)
  model_vars <- rownames(rf_model$importance)
  message(paste("  Model features:", paste(model_vars, collapse = ", ")))

  hist_data <- read_csv(cfg$data_file, show_col_types = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    arrange(date)

  # 2. Persistence / Real-time O3
  realtime_o3 <- get_latest_hourly_o3(cfg$aqs_id)
  if (!is.na(realtime_o3)) {
    today_o3 <- realtime_o3
    message(paste("  Real-time Ozone:", round(today_o3, 4)))
  } else {
    today_o3 <- (hist_data %>% filter(!is.na(O3)) %>% tail(1))$O3
    message(paste("  Using fallback Ozone (persistence):", round(today_o3, 4)))
  }

  # 3. Weather Forecast
  met <- get_nws_forecast(cfg$lat, cfg$lon)

  # Safe extraction helper with historic persistence
  get_weather_val <- function(met_obj, key, fallback_val) {
    val <- met_obj[[key]]
    if (is.null(val) || is.na(val)) {
      return(fallback_val)
    }
    return(val)
  }

  m_temp <- get_weather_val(met, "max_temp_f", (hist_data %>% filter(!is.na(max_temp_f)) %>% tail(1))$max_temp_f)
  m_ws <- get_weather_val(met, "ws", (hist_data %>% filter(!is.na(ws)) %>% tail(1))$ws)
  m_dp <- get_weather_val(met, "min_dewpoint_f", (hist_data %>% filter(!is.na(min_dewpoint_f)) %>% tail(1))$min_dewpoint_f)
  m_wd <- get_weather_val(met, "wd", (hist_data %>% filter(!is.na(wd)) %>% tail(1))$wd)

  # Explicitly find lagged O3 and weather to be robust
  get_feat_robust <- function(df, dt, col, name) {
    # 1. Try exact date match
    val <- (df %>% filter(as.Date(date) == as.Date(dt)))[[col]]
    if (length(val) > 0 && !is.na(val[1])) {
      return(as.numeric(val[1]))
    }

    # 2. Fallback: Find the latest non-NA value *on or before* that date
    message(paste("    Warning: Missing exact match for", name, "on", dt, ". Using latest available non-NA..."))
    fallback_val <- (df %>% filter(as.Date(date) <= as.Date(dt), !is.na(!!sym(col))) %>% tail(1))[[col]]
    if (length(fallback_val) > 0) {
      return(as.numeric(fallback_val[1]))
    }

    return(NA)
  }

  # 4. NOAA AQM
  target_dt <- Sys.Date() + days(1)

  # Part A: Retrospective Gap-Filling
  log_file <- paste0("history_", gsub(" ", "_", site_name), ".csv")
  if (file.exists(log_file)) {
    hist_log <- read_csv(log_file, show_col_types = FALSE) %>% mutate(Target_Date = as.Date(Target_Date), Run_Date = as.Date(Run_Date))

    # Purge any off-season rows for seasonal sites (no monitor running)
    if (cfg$seasonal) {
      off <- month(hist_log$Target_Date) %in% c(11, 12, 1) |
             (month(hist_log$Target_Date) == 2 & day(hist_log$Target_Date) < 15)
      if (any(off)) {
        hist_log <- hist_log[!off, ]
        message(paste("  Purged", sum(off), "off-season rows from history."))
      }
    }

    # Re-enable checking up to Sys.Date() since the `needs_fill` boolean guarantees we never overwrite healthy `RF_Pred` data now.
    # Window is 14 days: NOAA's S3 cache only holds recent runs, so older gaps can't be filled retroactively anyway.
    gap_dates <- seq(Sys.Date() - 14, Sys.Date(), by = "day")
    for (g_date in gap_dates) {
      g_date <- as.Date(g_date, origin = "1970-01-01")

      needs_fill <- FALSE
      if (!(as.character(g_date) %in% as.character(hist_log$Target_Date))) {
        needs_fill <- TRUE
      } else {
        existing_row <- hist_log %>%
          filter(as.character(Target_Date) == as.character(g_date)) %>%
          head(1)
        # Re-fill if predictions are missing OR if observed data is missing for a past date
        if (is.na(existing_row$RF_Pred) || is.na(existing_row$AQM_06_Reg) || (is.na(existing_row$Observed_O3) && g_date < Sys.Date())) {
          needs_fill <- TRUE
        }
      }

      if (cfg$seasonal) {
        g_month <- month(g_date)
        g_day <- day(g_date)
        if (g_month %in% c(11, 12, 1) || (g_month == 2 && g_day < 15)) {
          # Skip this specific target date because it's in the offseason
          needs_fill <- FALSE
        }
      }

      if (needs_fill) {
        message(paste("  Gap/Missing data detected for Target Date:", g_date, ". Attempting retrospective fill..."))
        run_dt <- g_date - 1
        d_sub <- hist_data %>% filter(date <= run_dt)
        g_met <- hist_data %>% filter(date == g_date)

        g_pred <- NA
        if (nrow(g_met) == 0) {
          # Construct mock meteorological inputs for missing ASOS weather using latest valid readings
          g_met <- tibble(
            date = g_date,
            O3 = NA,
            max_temp_f = get_feat_robust(hist_data, g_date, "max_temp_f", "max_temp_f"),
            min_dewpoint_f = get_feat_robust(hist_data, g_date, "min_dewpoint_f", "min_dewpoint_f"),
            ws = get_feat_robust(hist_data, g_date, "ws", "ws"),
            wd = get_feat_robust(hist_data, g_date, "wd", "wd")
          )
        }

        if (nrow(d_sub) >= 5 && nrow(g_met) > 0) {
          rt_o3 <- (d_sub %>% filter(!is.na(O3)) %>% tail(1))$O3
          if (length(rt_o3) > 0 && !is.na(rt_o3)) {
            try(
              {
                rt_lag1 <- (d_sub %>% filter(date <= run_dt - 1, !is.na(O3)) %>% tail(1))$O3
                rt_lag2 <- (d_sub %>% filter(date <= run_dt - 2, !is.na(O3)) %>% tail(1))$O3
                inp <- tibble(
                  O3 = as.numeric(rt_o3),
                  O3_lag1 = if (length(rt_lag1) > 0) as.numeric(rt_lag1) else NA,
                  O3_lag2 = if (length(rt_lag2) > 0) as.numeric(rt_lag2) else NA,
                  max_temp_f = as.numeric((d_sub %>% filter(!is.na(max_temp_f)) %>% tail(1))$max_temp_f),
                  min_dewpoint_f = as.numeric((d_sub %>% filter(!is.na(min_dewpoint_f)) %>% tail(1))$min_dewpoint_f),
                  ws = as.numeric((d_sub %>% filter(!is.na(ws)) %>% tail(1))$ws),
                  wd = as.numeric((d_sub %>% filter(!is.na(wd)) %>% tail(1))$wd),
                  max_temp_f_lag1 = as.numeric((d_sub %>% filter(date <= run_dt - 1, !is.na(max_temp_f)) %>% tail(1))$max_temp_f),
                  min_dewpoint_f_lag1 = as.numeric((d_sub %>% filter(date <= run_dt - 1, !is.na(min_dewpoint_f)) %>% tail(1))$min_dewpoint_f),
                  ws_lag1 = as.numeric((d_sub %>% filter(date <= run_dt - 1, !is.na(ws)) %>% tail(1))$ws),
                  wd_lag1 = as.numeric((d_sub %>% filter(date <= run_dt - 1, !is.na(wd)) %>% tail(1))$wd),
                  max_temp_f_next = as.numeric(g_met$max_temp_f[1]),
                  min_dewpoint_f_next = as.numeric(g_met$min_dewpoint_f[1]),
                  ws_next = as.numeric(g_met$ws[1]),
                  wd_next = as.numeric(g_met$wd[1])
                )
                if ("doy" %in% model_vars) inp$doy <- as.numeric(format(g_date, "%j"))
                if ("is_weekend" %in% model_vars) inp$is_weekend <- as.numeric(weekdays(g_date) %in% c("Saturday", "Sunday"))
                if ("td_spread" %in% model_vars) inp$td_spread <- as.numeric(inp$max_temp_f) - as.numeric(inp$min_dewpoint_f)
                if (!any(is.na(inp))) {
                  g_pred <- round(as.numeric(predict(rf_model, inp)), 4)
                }
              },
              silent = TRUE
            )
          }
        }

        h_aqm06_reg <- get_aqm_forecast(cfg$lat, cfg$lon, g_date, "06", FALSE)
        h_aqm06_bc <- get_aqm_forecast(cfg$lat, cfg$lon, g_date, "06", TRUE)
        h_aqm12_reg <- get_aqm_forecast(cfg$lat, cfg$lon, g_date, "12", FALSE)
        h_aqm12_bc <- get_aqm_forecast(cfg$lat, cfg$lon, g_date, "12", TRUE)

        obs_o3_val <- if (nrow(g_met) > 0) as.numeric(g_met$O3[1]) else NA
        met_t_val <- if (nrow(g_met) > 0) round(as.numeric(g_met$max_temp_f[1]), 1) else NA
        met_dp_val <- if (nrow(g_met) > 0) round(as.numeric(g_met$min_dewpoint_f[1]), 1) else NA
        met_ws_val <- if (nrow(g_met) > 0) round(as.numeric(g_met$ws[1]), 1) else NA
        met_wd_val <- if (nrow(g_met) > 0) round(as.numeric(g_met$wd[1]), 0) else NA

        new_row <- tibble(
          Run_Date = run_dt, Target_Date = g_date, RF_Pred = g_pred, Observed_O3 = obs_o3_val,
          AQM_06_Reg = round(as.numeric(h_aqm06_reg$val), 4), AQM_06_BC = round(as.numeric(h_aqm06_bc$val), 4),
          AQM_12_Reg = round(as.numeric(h_aqm12_reg$val), 4), AQM_12_BC = round(as.numeric(h_aqm12_bc$val), 4),
          Met_Temp_F = met_t_val, Met_Dewp_F = met_dp_val,
          Met_WS_kts = met_ws_val, Met_WD_deg = met_wd_val,
          # Built from observed target-day meteorology -- perfect prognosis.
          Forecast_Type = "hindcast"
        )
        hist_log <- hist_log %>%
          filter(as.character(Target_Date) != as.character(g_date)) %>%
          bind_rows(new_row) %>%
          distinct(Run_Date, Target_Date, .keep_all = T)
      }
    }
    write_csv(hist_log, log_file)
  }

  # Part B: Tomorrow's Forecast (issued Today)
  if (cfg$seasonal) {
    t_month <- month(target_dt)
    t_day <- day(target_dt)
    if (t_month %in% c(11, 12, 1) || (t_month == 2 && t_day < 15)) {
      message("  Off-season tomorrow. Skipping real-time prediction.")
      return(NULL)
    }
  }

  aqm06_reg <- get_aqm_forecast(cfg$lat, cfg$lon, target_dt, "06", FALSE)
  aqm06_bc <- get_aqm_forecast(cfg$lat, cfg$lon, target_dt, "06", TRUE)
  aqm12_reg <- get_aqm_forecast(cfg$lat, cfg$lon, target_dt, "12", FALSE)
  aqm12_bc <- get_aqm_forecast(cfg$lat, cfg$lon, target_dt, "12", TRUE)

  # 5. ML Prediction — detect which features the model expects
  model_vars <- names(rf_model$forest$xlevels)
  if (length(model_vars) == 0) model_vars <- rownames(rf_model$importance)

  input_row <- tibble(
    O3 = as.numeric(today_o3),
    O3_lag1 = get_feat_robust(hist_data, Sys.Date() - 1, "O3", "O3_lag1"),
    O3_lag2 = get_feat_robust(hist_data, Sys.Date() - 2, "O3", "O3_lag2"),
    max_temp_f = get_feat_robust(hist_data, Sys.Date(), "max_temp_f", "max_temp_f"),
    min_dewpoint_f = get_feat_robust(hist_data, Sys.Date(), "min_dewpoint_f", "min_dewpoint_f"),
    ws = get_feat_robust(hist_data, Sys.Date(), "ws", "ws"),
    wd = get_feat_robust(hist_data, Sys.Date(), "wd", "wd"),
    max_temp_f_lag1 = get_feat_robust(hist_data, Sys.Date() - 1, "max_temp_f", "max_temp_f_lag1"),
    min_dewpoint_f_lag1 = get_feat_robust(hist_data, Sys.Date() - 1, "min_dewpoint_f", "min_dewpoint_f_lag1"),
    ws_lag1 = get_feat_robust(hist_data, Sys.Date() - 1, "ws", "ws_lag1"),
    wd_lag1 = get_feat_robust(hist_data, Sys.Date() - 1, "wd", "wd_lag1"),
    max_temp_f_next = as.numeric(m_temp),
    min_dewpoint_f_next = as.numeric(m_dp),
    ws_next = as.numeric(m_ws),
    wd_next = as.numeric(m_wd)
  )

  # Add enhanced features if the model was trained with them
  if ("doy" %in% model_vars) {
    input_row$doy <- as.numeric(format(target_dt, "%j"))
  }
  if ("is_weekend" %in% model_vars) {
    input_row$is_weekend <- as.numeric(weekdays(target_dt) %in% c("Saturday", "Sunday"))
  }
  if ("td_spread" %in% model_vars) {
    input_row$td_spread <- as.numeric(input_row$max_temp_f) - as.numeric(input_row$min_dewpoint_f)
  }

  # Check for NAs
  pred_val <- NA
  if (!any(is.na(input_row))) {
    pred <- predict(rf_model, input_row)
    pred_val <- as.numeric(pred)
    message(paste("  RF Prediction:", round(pred_val, 4)))
  } else {
    # Last resort: log which ones are still NA
    nas <- names(input_row)[colSums(is.na(input_row)) > 0]
    message(paste("  Warning: Still missing features after robust check:", paste(nas, collapse = ", ")))
    message("  RF Pred set to NA.")
  }

  # 6. History Management & Verification
  log_file <- paste0("history_", gsub(" ", "_", site_name), ".csv")

  # Standard column order.
  #
  # Forecast_Type records how RF_Pred was produced, which is essential for honest
  # verification:
  #   "operational" - issued ahead of time using the NWS *forecast* meteorology,
  #                   i.e. a real forecast.
  #   "hindcast"    - reconstructed by the retrospective gap-fill above using the
  #                   *observed* ASOS meteorology for the target day. This is a
  #                   perfect-prognosis run and scores far better than the model
  #                   can achieve operationally, so hindcast and operational rows
  #                   must not be pooled into one skill score.
  # Legacy rows written before this column existed are left NA (unknown).
  cols_standard <- c(
    "Run_Date", "Target_Date", "Observed_O3", "RF_Pred",
    "AQM_06_Reg", "AQM_06_BC", "AQM_12_Reg", "AQM_12_BC",
    "Met_Temp_F", "Met_Dewp_F", "Met_WS_kts", "Met_WD_deg",
    "Forecast_Type"
  )

  # New entry for today's run
  entry <- tibble(
    Run_Date = Sys.Date(),
    Target_Date = target_dt,
    Observed_O3 = as.numeric(NA), # Placeholder for tomorrow
    RF_Pred = round(pred_val, 4),
    AQM_06_Reg = round(as.numeric(aqm06_reg$val), 4),
    AQM_06_BC = round(as.numeric(aqm06_bc$val), 4),
    AQM_12_Reg = round(as.numeric(aqm12_reg$val), 4),
    AQM_12_BC = round(as.numeric(aqm12_bc$val), 4),
    Met_Temp_F = round(as.numeric(m_temp), 1),
    Met_Dewp_F = round(as.numeric(m_dp), 1),
    Met_WS_kts = round(as.numeric(m_ws), 1),
    Met_WD_deg = round(as.numeric(m_wd), 0),
    # Issued ahead of the target day off the NWS forecast -- a real forecast.
    Forecast_Type = "operational"
  ) %>% select(all_of(cols_standard))

  if (file.exists(log_file)) {
    hist_log <- read_csv(log_file, show_col_types = FALSE)

    # Ensure all standard columns exist. Forecast_Type is character, so seeding it
    # with a numeric NA would make the later bind_rows() fail on a type clash.
    for (c in cols_standard) {
      if (!(c %in% colnames(hist_log))) {
        hist_log[[c]] <- if (c == "Forecast_Type") NA_character_ else as.numeric(NA)
      }
    }

    # Retroactive Verification: Try to fill in missing Observed_O3 from historical data for strictly PAST dates
    needs_verify <- is.na(hist_log$Observed_O3) & hist_log$Target_Date < Sys.Date()

    if (any(needs_verify)) {
      message("  Verifying past forecasts (retroactive check)...")
      obs_data <- hist_data %>%
        select(date, O3) %>%
        filter(!is.na(O3))

      for (i in which(needs_verify)) {
        t_date <- as.Date(hist_log$Target_Date[i])
        match_val <- obs_data$O3[as.Date(obs_data$date) == t_date]
        if (length(match_val) > 0) {
          hist_log$Observed_O3[i] <- match_val[1]
        }
      }
    }

    # Upsert logic and re-standardize order
    hist_log <- hist_log %>%
      filter(!(as.character(Run_Date) == as.character(entry$Run_Date) &
        as.character(Target_Date) == as.character(entry$Target_Date))) %>%
      bind_rows(entry) %>%
      select(all_of(cols_standard)) %>%
      arrange(desc(Run_Date))
  } else {
    hist_log <- entry
  }

  write_csv(hist_log, log_file)
  return(pred_val)
}

# Run for all sites by default if executed as a script
if (sys.nframe() == 0) {
  forecast_results <- list()

  for (site in names(SITES_CONFIG)) {
    res <- try(run_forecast(site))
    if (!inherits(res, "try-error") && !is.null(res)) {
      forecast_results[[site]] <- res
    }
  }

  message("\n", paste(rep("=", 50), collapse = ""))
  message(" CONSOLIDATED FORECAST REPORT | ", Sys.Date() + days(1))
  message(paste(rep("=", 50), collapse = ""))
  if (length(forecast_results) > 0) {
    for (site in names(forecast_results)) {
      message(sprintf("%-20s : %.4f ppm", site, forecast_results[[site]]))
    }
  } else {
    message(" No forecasts were generated successfully.")
  }
  message(paste(rep("=", 50), collapse = ""))
}
