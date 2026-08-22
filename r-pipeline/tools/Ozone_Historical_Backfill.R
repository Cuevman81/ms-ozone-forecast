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

library(terra)
library(dplyr)
library(readr)
library(lubridate)
library(parallel)

source("sites_config.R")

fetch_aqm_value <- function(url, lat, lon, target_date) {
  tf <- tempfile(fileext = ".grib2")
  on.exit(if (file.exists(tf)) unlink(tf))

  tryCatch({
    if (suppressWarnings(download.file(url, tf, mode = "wb", quiet = TRUE)) == 0) {
      if (file.info(tf)$size > 1000) {
        r <- terra::rast(tf)
        pts <- terra::vect(cbind(lon, lat), crs = "EPSG:4326")

        t_str <- format(terra::time(r), "%Y-%m-%d", tz = "UTC")
        idx <- which(t_str == as.character(target_date))
        if (length(idx) == 0) return(NA)

        val <- terra::extract(r[[idx[1]]], pts)[1, 2]
        if (!is.na(val) && val > 1) val <- val / 1000
        return(as.numeric(val))
      }
    }
  }, error = function(e) NULL)
  return(NA)
}

fetch_aqm_with_fallback <- function(lat, lon, target_date, cycle, type_str) {
  run_dates <- c(as.Date(target_date) - 1, as.Date(target_date) - 2)
  for (run_dt in run_dates) {
    run_dt <- as.Date(run_dt, origin = "1970-01-01")
    run_str <- format(run_dt, "%Y%m%d")
    url <- paste0(
      "https://noaa-nws-naqfc-pds.s3.amazonaws.com/AQMv7/CS/",
      run_str, "/", cycle, "/aqm.t", cycle, "z.", type_str, ".",
      run_str, ".227.grib2"
    )
    val <- fetch_aqm_value(url, lat, lon, target_date)
    if (!is.na(val)) return(val)
  }
  return(NA)
}

backfill_socket <- function(site_name, cores = 4) {
  config <- SITES_CONFIG[[site_name]]
  log_file <- paste0("history_", gsub(" ", "_", site_name), ".csv")

  if (!file.exists(log_file)) return()

  df <- read_csv(log_file, show_col_types = FALSE) %>%
    mutate(Target_Date = as.Date(Target_Date))

  # Blank all AQM columns so no old wrong-CRS data survives
  aqm_cols <- c("AQM_06_Reg", "AQM_06_BC", "AQM_12_Reg", "AQM_12_BC")
  for (col in aqm_cols) {
    if (col %in% names(df)) df[[col]] <- NA_real_
  }
  write_csv(df, log_file)
  message("   Blanked all AQM columns for clean re-extraction.")

  is_offseason <- function(d) {
    m <- month(d); dy <- day(d)
    m %in% c(11, 12, 1) || (m == 2 && dy < 15)
  }

  in_season <- if (config$seasonal) !sapply(df$Target_Date, is_offseason) else rep(TRUE, nrow(df))
  rows_to_fill <- which(year(df$Target_Date) %in% c(2024, 2025, 2026) & in_season)

  if (length(rows_to_fill) == 0) {
    message("   No rows to process for: ", site_name)
    return()
  }

  message("   Re-extracting AQM for ", length(rows_to_fill), " dates for ", site_name,
          " using ", cores, " socket workers...")

  cl <- makePSOCKcluster(cores)
  clusterExport(cl, c("fetch_aqm_value", "fetch_aqm_with_fallback", "config"),
                envir = environment())
  clusterEvalQ(cl, library(terra))

  batch_size <- cores * 4
  total_batches <- ceiling(length(rows_to_fill) / batch_size)

  for (b in 1:total_batches) {
    idx <- ((b - 1) * batch_size + 1):min(b * batch_size, length(rows_to_fill))
    curr_rows <- rows_to_fill[idx]

    results <- parLapply(cl, curr_rows, function(r_idx) {
      dt <- df$Target_Date[r_idx]

      data.frame(
        row = r_idx,
        reg06 = fetch_aqm_with_fallback(config$lat, config$lon, dt, "06", "max_8hr_o3"),
        bc06  = fetch_aqm_with_fallback(config$lat, config$lon, dt, "06", "max_8hr_o3_bc"),
        reg12 = fetch_aqm_with_fallback(config$lat, config$lon, dt, "12", "max_8hr_o3"),
        bc12  = fetch_aqm_with_fallback(config$lat, config$lon, dt, "12", "max_8hr_o3_bc")
      )
    })

    batch_df <- bind_rows(results)
    for (i in 1:nrow(batch_df)) {
      r <- batch_df$row[i]
      if (!is.na(batch_df$reg06[i])) df$AQM_06_Reg[r] <- round(batch_df$reg06[i], 4)
      if (!is.na(batch_df$bc06[i]))  df$AQM_06_BC[r]  <- round(batch_df$bc06[i], 4)
      if (!is.na(batch_df$reg12[i])) df$AQM_12_Reg[r] <- round(batch_df$reg12[i], 4)
      if (!is.na(batch_df$bc12[i]))  df$AQM_12_BC[r]  <- round(batch_df$bc12[i], 4)
    }

    message("      Progress: Batch ", b, "/", total_batches,
            " (", format(df$Target_Date[curr_rows[1]], "%Y-%m"), ")")
    write_csv(df, log_file)
  }

  stopCluster(cl)
  message("   COMPLETE for ", site_name)
}

for (site in names(SITES_CONFIG)) {
  message("\n>>> STARTING RE-EXTRACTION FOR: ", site)
  backfill_socket(site, cores = 4)
  message(">>> FINISHED RE-EXTRACTION FOR: ", site, "\n")
}
