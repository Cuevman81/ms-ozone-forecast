# Ozone_Data_Manager.R
# Automates fetching of Ozone and Meteorological data for Mississippi monitoring sites.

library(RAQSAPI)
library(lubridate)
library(readr)
library(dplyr)

# Load Site Configuration
source("sites_config.R")

# --- Configuration ---
# Credentials are read from ~/.Renviron (outside OneDrive).
# If you ever see this error, edit ~/.Renviron and restart R.
EMAIL      <- Sys.getenv("AQS_EMAIL")
KEY        <- Sys.getenv("AQS_KEY")
AIRNOW_KEY <- Sys.getenv("AIRNOW_API_KEY")
PARAM      <- "44201"

if (EMAIL == "" || KEY == "") {
  stop("AQS_EMAIL / AQS_KEY not set. Add them to ~/.Renviron and restart R.")
}

# Initialize RAQSAPI
aqs_credentials(username = EMAIL, key = KEY)

# Function to fetch Daily O3 from AirNow S3 (as fallback)
get_airnow_s3_historical_o3 <- function(aqs_id, start_date, end_date) {
  clean_aqs <- gsub("-", "", aqs_id)
  dates <- seq(as.Date(start_date), as.Date(end_date), by = "day")
  results <- list()

  for (d in as.character(dates)) {
    d_dt <- as.Date(d)
    y_str <- format(d_dt, "%Y")
    ymd_str <- format(d_dt, "%Y%m%d")

    url <- paste0(
      "https://s3-us-west-1.amazonaws.com/files.airnowtech.org/airnow/",
      y_str, "/", ymd_str, "/daily_data_v2.dat"
    )

    tryCatch(
      {
        tf <- tempfile()
        suppressWarnings(download.file(url, tf, quiet = TRUE))

        if (file.info(tf)$size > 10) {
          # Read pipe-delimited file
          df <- read_delim(tf, delim = "|", col_names = FALSE, show_col_types = FALSE, col_types = cols(.default = "c"))

          # Filter for target site and PARAMETER (Strict 8-hour match)
          df_sub <- df %>%
            filter(trimws(X2) == clean_aqs & X4 == "OZONE-8HR")

          if (nrow(df_sub) > 0) {
            # Use X6 for the actual value, X5 is unit (PPB)
            val <- as.numeric(df_sub$X6[1])
            message(paste("      Found AirNow O3 (8-hour) for", d, ":", val))
            results[[d]] <- data.frame(date = d_dt, O3 = val / 1000)
          }
        }
        unlink(tf)
      },
      error = function(e) {
        if (exists("tf")) unlink(tf)
      }
    )
  }
  return(dplyr::bind_rows(results))
}

# Function to update data for a specific site
update_site_data <- function(site_name) {
  cfg <- SITES_CONFIG[[site_name]]
  if (is.null(cfg)) stop(paste("Site", site_name, "not found in config."))

  message(paste("\n--- Processing Site:", site_name, "(", cfg$aqs_id, ") ---"))
  message(paste("  Monitoring Type:", if (cfg$seasonal) "Seasonal (Mar-Oct)" else "Year-Round"))

  STATE <- cfg$state
  COUNTY <- cfg$county
  SITE <- cfg$site
  ASOS_STATION <- cfg$asos
  DATA_FILE <- cfg$data_file

  # Check for existing data
  existing_data <- NULL
  start_date <- NULL

  if (file.exists(DATA_FILE)) {
    message("  Found existing data file. Checking for updates...")
    tryCatch(
      {
        existing_data <- read_csv(DATA_FILE, show_col_types = FALSE) %>%
          mutate(date = as.Date(date))

        if (nrow(existing_data) > 0) {
          # Gap-Aware Logic: Look back 14 days for any NAs in Ozone that should be filled
          recent_window <- existing_data %>% filter(date >= (Sys.Date() - days(14)))
          earliest_gap <- recent_window$date[which(is.na(recent_window$O3))]

          if (length(earliest_gap) > 0) {
            start_date <- min(earliest_gap)
            message(paste("  [GAP-FILL] Missing data detected on:", start_date, ". Attempting to re-fetch..."))
          } else {
            valid_dates <- existing_data$date[!is.na(existing_data$O3)]
            last_date <- if (length(valid_dates) > 0) max(valid_dates, na.rm = TRUE) else min(existing_data$date, na.rm = TRUE) - 1
            start_date <- last_date + 1
            message(paste("  Existing data up to:", last_date))
          }
        }
      },
      error = function(e) {
        message("  Error reading existing file. Starting fresh.")
        existing_data <- NULL
      }
    )
  }

  if (is.null(start_date)) {
    # Get Monitor metadata to find open_date if starting fresh
    tryCatch(
      {
        monitors <- aqs_monitors_by_site(
          parameter = PARAM, stateFIPS = STATE,
          countycode = COUNTY, sitenum = SITE,
          bdate = as.Date("2010-01-01"), edate = Sys.Date()
        )
        start_date <- as.Date(monitors$open_date[1])
      },
      error = function(e) {
        start_date <- as.Date("2020-01-01")
      }
    )
    message(paste("  Starting fresh from monitor open date:", start_date))
  }

  # Log data up to YESTERDAY to ensure complete daily records
  end_date <- Sys.Date() - days(1)

  if (cfg$seasonal) {
    # If seasonal, do not try to fetch data between Nov 1st and Feb 14th
    current_month <- month(Sys.Date())
    current_day <- day(Sys.Date())

    if (current_month %in% c(11, 12, 1) || (current_month == 2 && current_day < 15)) {
      message("  Off-season detected for seasonal site. Halting data sync until Feb 15th startup.")
      return(invisible(NULL))
    }
  }

  if (start_date > end_date) {
    message("  Data is already fully up to date!")
    return(invisible(NULL))
  }

  message(paste("  Fetching NEW Ozone data from", start_date, "to", end_date))

  years <- year(start_date):year(end_date)
  data_list <- list()

  for (yr in years) {
    bdate <- as.Date(paste0(yr, "-01-01"))
    if (yr == year(start_date)) bdate <- start_date

    edate_val <- as.Date(paste0(yr, "-12-31"))
    if (edate_val > end_date) edate_val <- end_date
    if (bdate > end_date) next

    message(paste("    Fetching year:", yr))
    tryCatch(
      {
        O3_Daily <- aqs_dailysummary_by_site(
          parameter = PARAM,
          stateFIPS = STATE,
          countycode = COUNTY,
          sitenum = SITE,
          bdate = bdate,
          edate = edate_val
        )
        if (!is.null(O3_Daily) && nrow(O3_Daily) > 0) {
          data_list[[as.character(yr)]] <- O3_Daily
        }
      },
      error = function(e) {
        message(paste("      Error fetching year", yr, ":", e$message))
      }
    )
  }

  combined_o3 <- dplyr::bind_rows(data_list)

  # Fallback to AirNow for 2026 if AQS is empty or delayed
  cur_max_date <- if (nrow(combined_o3) > 0 && "date_local" %in% names(combined_o3)) {
    max(as.Date(combined_o3$date_local), na.rm = TRUE)
  } else {
    start_date - 1
  }

  if (nrow(combined_o3) == 0 || cur_max_date < end_date) {
    message("    AQS data looks incomplete for recent days. Trying AirNow fallback...")
    an_start <- max(cur_max_date + 1, start_date)

    if (an_start <= end_date) {
      an_data <- get_airnow_s3_historical_o3(cfg$aqs_id, an_start, end_date)
      if (nrow(an_data) > 0) {
        an_formatted <- an_data %>%
          dplyr::rename(date_local = date, first_max_value = O3) %>%
          dplyr::mutate(pollutant_standard = "Ozone 8-hour 2015", date_local = as.character(date_local))
        combined_o3 <- dplyr::bind_rows(combined_o3, an_formatted)
      }
    }
  }

  # Determine complete sequence of dates we need to fetch
  full_dates <- data.frame(date = seq.Date(start_date, end_date, by = "day"))

  if (nrow(combined_o3) > 0) {
    filtered_o3 <- combined_o3 %>%
      dplyr::filter(pollutant_standard == "Ozone 8-hour 2015") %>%
      dplyr::select(date_local, first_max_value) %>%
      dplyr::rename(date = date_local, O3 = first_max_value) %>%
      dplyr::mutate(date = as.Date(date))
  } else {
    filtered_o3 <- data.frame(date = as.Date(character()), O3 = numeric())
    message("  No new Ozone records returned from AQS/AirNow across this window. Saving pure Meteorology data.")
  }

  merged_o3 <- dplyr::left_join(full_dates, filtered_o3, by = "date") %>%
    dplyr::distinct(date, .keep_all = TRUE)

  # --- ASOS Meteorological Data ---
  message(paste("  Fetching NEW Meteorological data from ASOS (", ASOS_STATION, ")..."))
  network <- if (ASOS_STATION == "MEM") "TN_ASOS" else "MS_ASOS"

  met_url <- paste0(
    "https://mesonet.agron.iastate.edu/cgi-bin/request/daily.py?network=", network,
    "&stations=", ASOS_STATION, "&year1=", year(start_date), "&month1=", month(start_date), "&day1=", day(start_date),
    "&year2=", year(end_date), "&month2=", month(end_date), "&day2=", day(end_date)
  )

  met_data <- tryCatch(
    {
      read_csv(met_url, na = c("", "NA", "M", "None"), show_col_types = FALSE) %>%
        dplyr::rename(date = day, ws = avg_wind_speed_kts, wd = avg_wind_drct) %>%
        dplyr::mutate(date = as.Date(date)) %>%
        dplyr::mutate(across(c(max_temp_f, min_temp_f, max_dewpoint_f, min_dewpoint_f, ws, wd), as.numeric))
    },
    error = function(e) {
      message("    Error fetching meteorology. Proceeding with NA values.")
      return(data.frame(date = merged_o3$date, max_temp_f = NA, min_temp_f = NA, max_dewpoint_f = NA, min_dewpoint_f = NA, ws = NA, wd = NA))
    }
  )

  # --- Merging ---
  message("  Merging new data...")
  new_merged <- dplyr::left_join(merged_o3, met_data, by = "date") %>%
    dplyr::distinct(date, .keep_all = TRUE)

  if (!is.null(existing_data)) {
    final_data <- dplyr::bind_rows(existing_data %>% filter(date < start_date), new_merged) %>%
      dplyr::arrange(date)
  } else {
    final_data <- new_merged %>% dplyr::arrange(date)
  }

  # Null out O3 during off-season for seasonal sites — no monitor is running
  if (cfg$seasonal) {
    off <- month(final_data$date) %in% c(11, 12, 1) |
           (month(final_data$date) == 2 & day(final_data$date) < 15)
    final_data$O3[off] <- NA
  }

  write_csv(final_data, DATA_FILE)
  message(paste("  SUCCESS: Site", site_name, "updated with", nrow(new_merged), "NEW rows. Total:", nrow(final_data)))
}

# Run for all sites by default if executed as a script
if (sys.nframe() == 0) {
  for (site in names(SITES_CONFIG)) {
    try(update_site_data(site))
  }
}
