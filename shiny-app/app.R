# app.R - Ozone Forecast Shiny Application for Hernando, MS
# Integrates Data Management, Model Training, and Forecasting.

library(shiny)
library(shinydashboard)
library(bslib)
library(leaflet)
library(thematic)
library(dplyr)
library(lubridate)
library(readr)
library(randomForest)
library(terra)
library(ggplot2)
library(caret)
library(httr2)
library(jsonlite)
library(purrr)
library(DT)
library(plotly)
library(Metrics)
library(RAQSAPI)

# Initialize thematic for consistent plot styling
thematic_shiny()

options(timeout = max(300, getOption("timeout")))

# --- Single source of truth for data, models, and history ---
# GitHub Actions refreshes r-pipeline/ twice daily and the web dashboard exports
# its JSON from there. Point this app at the same directory so the Shiny app, the
# web dashboard, and the pipeline always agree. Resolved before anything else,
# because sites_config.R is read from it too rather than kept as a second copy.
# Paths are absolute so they survive any setwd() during a sync.
DATA_DIR <- local({
  # Covers running from inside the repo (shiny-app/), from the project root
  # beside web-dashboard/, or from the pipeline directory itself. First candidate
  # that actually holds the data files wins.
  candidates <- c(
    file.path("..", "r-pipeline"),
    file.path("web-dashboard", "r-pipeline"),
    "r-pipeline",
    "."
  )
  hit <- Filter(function(d) file.exists(file.path(d, "sites_config.R")), candidates)
  if (length(hit) == 0) {
    stop(
      "Could not find the pipeline data directory (no sites_config.R in any of: ",
      paste(candidates, collapse = ", "), "). Working directory is: ", getwd()
    )
  }
  normalizePath(hit[1])
})
message("Reading data from: ", DATA_DIR)

# --- Configuration & Shared Variables ---
source(file.path(DATA_DIR, "sites_config.R"))
AIRNOW_KEY <- Sys.getenv("AIRNOW_API_KEY")

# Rewrite a site's bare filenames into absolute paths under DATA_DIR.
resolve_site_paths <- function(cfg, site_name) {
  cfg$data_file <- file.path(DATA_DIR, basename(cfg$data_file))
  cfg$model_file <- file.path(DATA_DIR, basename(cfg$model_file))
  cfg$history_file <- file.path(DATA_DIR, paste0("history_", gsub(" ", "_", site_name), ".csv"))
  cfg
}

# Group sites by region for UI
regions <- unique(sapply(SITES_CONFIG, function(x) x$region))

# --- Helper Functions ---

# NWS Weather Fetcher
get_nws_forecast <- function(lat, lon) {
  tryCatch(
    {
      point_url <- paste0("https://api.weather.gov/points/", lat, ",", lon)
      point_res <- request(point_url) %>%
        req_user_agent("HernandoOzoneApp") %>%
        req_perform() %>%
        resp_body_json()
      grid_url <- point_res$properties$forecastGridData
      grid_res <- request(grid_url) %>%
        req_user_agent("HernandoOzoneApp") %>%
        req_perform() %>%
        resp_body_json()

      parse_series <- function(series) {
        if (is.null(series) || is.null(series$values) || length(series$values) == 0) {
          return(NULL)
        }
        rows <- lapply(series$values, function(item) {
          dt <- ymd_hms(strsplit(item$validTime, "/")[[1]][1], quiet = TRUE)
          if (is.na(dt)) {
            return(NULL)
          }
          data.frame(datetime = dt, value = as.numeric(item$value))
        })
        do.call(rbind, rows)
      }

      target_date <- Sys.Date() + days(1)

      # Max Temperature
      df_temp <- parse_series(grid_res$properties$maxTemperature)
      max_temp_c <- if (!is.null(df_temp) && nrow(df_temp) > 0) {
        day_vals <- df_temp %>% filter(as.Date(datetime) == target_date)
        if (nrow(day_vals) > 0) max(day_vals$value, na.rm = T) else NA
      } else {
        NA
      }

      # Wind Speed
      df_ws <- parse_series(grid_res$properties$windSpeed)
      ws_kmh <- if (!is.null(df_ws) && nrow(df_ws) > 0) {
        day_vals <- df_ws %>% filter(as.Date(datetime) == target_date)
        if (nrow(day_vals) > 0) mean(day_vals$value, na.rm = T) else NA
      } else {
        NA
      }

      # Dewpoint
      df_dp <- parse_series(grid_res$properties$dewpoint)
      min_dp_c <- if (!is.null(df_dp) && nrow(df_dp) > 0) {
        day_vals <- df_dp %>% filter(as.Date(datetime) == target_date)
        if (nrow(day_vals) > 0) min(day_vals$value, na.rm = T) else NA
      } else {
        NA
      }

      # Wind Direction
      df_wd <- parse_series(grid_res$properties$windDirection)
      wd_deg <- if (!is.null(df_wd) && nrow(df_wd) > 0) {
        day_vals <- df_wd %>% filter(as.Date(datetime) == target_date)
        if (nrow(day_vals) > 0) mean(day_vals$value, na.rm = T) else NA
      } else {
        NA
      }

      return(list(
        max_temp_f = (max_temp_c * 9 / 5) + 32,
        ws = ws_kmh * 0.539957,
        min_dewpoint_f = (min_dp_c * 9 / 5) + 32,
        wd = wd_deg
      ))
    },
    error = function(e) list(max_temp_f = NA, ws = NA, min_dewpoint_f = NA, wd = NA)
  )
}

# AirNow Real-time Fetcher
get_latest_o3 <- function(aqs_id) {
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
        suppressWarnings(download.file(url, tf, quiet = T))
        if (file.info(tf)$size > 0) {
          df <- read_delim(tf, delim = "|", col_names = F, show_col_types = F)
          val_row <- df %>% filter(X3 == clean_aqs & X6 == "OZONE")
          if (nrow(val_row) > 0) {
            val <- as.numeric(val_row$X8[1]) / 1000
            unlink(tf)
            return(val)
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

# AQI Fetcher
get_aqm <- function(lat, lon, target_date, cycle, is_bc) {
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
          suppressWarnings(download.file(url, tf, mode = "wb", quiet = T))
          if (file.info(tf)$size > 1000) {
            r <- rast(tf)
            target_dt <- as.Date(target_date)
            idx <- which(format(time(r), "%Y-%m-%d", tz = "UTC") == as.character(target_dt))
            if (length(idx) > 0) {
              pts <- vect(cbind(lon, lat), crs = "EPSG:4326")
              val <- terra::extract(r[[idx[1]]], pts)[1, 2]
              if (!is.na(val) && val > 1) val <- val / 1000
              unlink(tf)
              return(list(val = val, date = as.character(as.Date(r_date, origin = "1970-01-01"))))
            }
          }
          unlink(tf)
        },
        error = function(e) {
          if (exists("tf") && file.exists(tf)) unlink(tf)
        }
      )
    }
  }
  return(list(val = NA, date = NA))
}

# AQI Info Helper
get_aqi_info <- function(ppm) {
  if (is.na(ppm) || !is.numeric(ppm)) {
    return(list(color = "blue", status = "Unknown", cat = 0))
  }
  if (ppm <= 0.054) {
    return(list(color = "green", status = "Good", cat = 1))
  }
  if (ppm <= 0.070) {
    return(list(color = "yellow", status = "Moderate", cat = 2))
  }
  if (ppm <= 0.085) {
    return(list(color = "orange", status = "Unhealthy for Sensitive Groups", cat = 3))
  }
  if (ppm <= 0.105) {
    return(list(color = "red", status = "Unhealthy", cat = 4))
  }
  if (ppm <= 0.200) {
    return(list(color = "purple", status = "Very Unhealthy", cat = 5))
  }
  return(list(color = "maroon", status = "Hazardous", cat = 6))
}

# --- UI ---
ui <- dashboardPage(
  skin = "blue",
  dashboardHeader(title = "MS Ozone Forecast"),
  dashboardSidebar(
    sidebarMenu(
      menuItem("Dashboard", tabName = "dashboard", icon = icon("tachometer-alt")),
      menuItem("Trends & Analysis", tabName = "analysis", icon = icon("chart-line")),
      menuItem("Data Management", tabName = "data", icon = icon("database")),
      menuItem("About Station", tabName = "about", icon = icon("info-circle"))
    ),
    hr(),
    div(
      style = "padding: 0 15px;",
      selectInput("region_select", "Select Region", choices = regions),
      selectInput("site_select", "Select Monitor Site", choices = NULL),
      hr(),
      h4(textOutput("sidebar_site_name")),
      leafletOutput("sidebar_map", height = "200px"),
      hr(),
      uiOutput("sidebar_status"),
      actionButton("master_sync", "Sync & Refresh Ecosystem", icon = icon("globe"), class = "btn-primary w-100", style = "margin-top: 5px;"),
      helpText("Updates data, models, and forecasts for all sites.", style = "color: #ccd; font-size: 0.8em; margin-top: 5px;")
    )
  ),
  dashboardBody(
    # Custom CSS for premium feel
    tags$head(
      tags$style(HTML("
        .content-wrapper { background-color: #f4f6f9; }
        .box { border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        .value-box { border-radius: 8px; }
        .main-header .logo { font-weight: bold; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
      "))
    ),
    tabItems(
      tabItem(
        tabName = "dashboard",
        fluidRow(
          valueBoxOutput("rf_box", width = 4),
          valueBoxOutput("aqm_box", width = 4),
          valueBoxOutput("met_box", width = 4)
        ),
        fluidRow(
          box(
            title = "Forecast Comparison (Today)", width = 6, status = "info", solidHeader = TRUE,
            DT::DTOutput("forecast_table_today")
          ),
          box(
            title = "Forecast Comparison (Tomorrow)", width = 6, status = "primary", solidHeader = TRUE,
            DT::DTOutput("forecast_table")
          )
        ),
        fluidRow(
          box(
            title = "7-Day Ozone Trend", width = 12, status = "info", solidHeader = TRUE,
            plotOutput("trend_plot", height = "300px")
          )
        )
      ),
      tabItem(
        tabName = "analysis",
        fluidRow(
          column(
            width = 8,
            box(
              title = "Model Diagnostics", width = NULL, status = "warning", solidHeader = TRUE,
              plotOutput("importance_plot", height = "300px")
            )
          ),
          column(
            width = 4,
            box(
              title = "Model Control", width = NULL, status = "danger", solidHeader = TRUE,
              uiOutput("model_status_label"),
              br(), br(),
              helpText("Updating the model uses the latest downloaded historical records."),
              actionButton("retrain_btn", "Retrain Model", icon = icon("brain"), class = "btn-warning w-100"),
              hr(),
              textOutput("metrics_text"),
              helpText(
                HTML(
                  "<b>Comparing RF against AQM:</b> most RF rows in the history log were ",
                  "reconstructed after the fact using the <i>observed</i> next-day weather, while ",
                  "the NOAA AQM values are genuine forecasts. Perfect-prognosis rows score much ",
                  "better than the model can achieve live, so the RF column flatters itself in any ",
                  "pooled comparison. The <i>Type</i> column in the Forecast History Log marks ",
                  "which rows are operational (real forecasts) versus hindcast; weigh the ",
                  "operational rows when judging live skill."
                ),
                style = "font-size: 0.78em; line-height: 1.5;"
              )
            )
          )
        ),
        fluidRow(
          box(
            width = 12, status = "primary",
            tabsetPanel(
              tabPanel("Performance Analysis",
                icon = icon("chart-line"),
                br(),
                fluidRow(
                  column(
                    width = 8,
                    plotlyOutput("perf_time_series", height = "400px"),
                    hr(),
                    fluidRow(
                      column(width = 6, plotlyOutput("perf_scatter", height = "350px")),
                      column(width = 6, plotlyOutput("perf_error_dist", height = "350px"))
                    )
                  ),
                  column(
                    width = 4,
                    h4("Overall Performance", style = "margin-top:0;"),
                    tableOutput("perf_metrics_table"),
                    hr(),
                    h4("Moderate+ Days (>= 55ppb)"),
                    tableOutput("perf_metrics_mod"),
                    hr(),
                    h4("USG+ Days (>= 71ppb)"),
                    tableOutput("perf_metrics_usg"),
                    hr(),
                    helpText(
                      HTML(
                        "Metrics compare each model against Observed O3.<br><br>",
                        "<b>Reading the threshold tables:</b> RMSE, Bias, NMB, NME and R-Squared ",
                        "are computed only on days where the <i>observed</i> value cleared the ",
                        "threshold. Conditioning on the observation this way narrows the spread of ",
                        "what is left, so R-Squared collapses toward 0 and bias turns negative even ",
                        "for a skillful model &mdash; this is a known artifact of conditional ",
                        "verification, not evidence the model failed. Judge event performance on ",
                        "POD / FAR / CSI (computed on the full record) and use the Overall table ",
                        "for correlation.<br><br>",
                        "<b>NMB / NME</b> are the EPA photochemical benchmarks ",
                        "(ozone: NMB within &plusmn;15%, NME under 25%)."
                      )
                    )
                  )
                )
              ),
              tabPanel("Forecast History Log",
                icon = icon("table"),
                br(),
                DT::DTOutput("history_table")
              )
            )
          )
        )
      ),
      tabItem(
        tabName = "data",
        fluidRow(
          infoBoxOutput("data_rows_box", width = 4),
          infoBoxOutput("data_date_box", width = 4),
          infoBoxOutput("data_status_box", width = 4)
        ),
        fluidRow(
          infoBoxOutput("data_start_box", width = 4),
          infoBoxOutput("data_exp_box", width = 4),
          infoBoxOutput("data_site_box", width = 4)
        ),
        fluidRow(
          box(
            title = "Raw Data Preview (Last 5 Rows)", width = 8, status = "primary", solidHeader = TRUE,
            DT::DTOutput("data_preview_table")
          ),
          box(
            title = "Update Data", width = 4, status = "success", solidHeader = TRUE,
            helpText("Downloads the latest AQS and Met data from AirNow and NWS repositories."),
            actionButton("update_btn", "Sync Historical Data", icon = icon("download"), class = "btn-success", width = "100%")
          )
        )
      ),
      tabItem(
        tabName = "about",
        fluidRow(
          column(width = 4,
            box(
              title = "Monitoring Site Profile", width = NULL, status = "info", solidHeader = TRUE,
              uiOutput("about_site_ui")
            ),
            box(
              title = "Model Details", width = NULL, status = "warning", solidHeader = TRUE,
              p(icon("brain", class="fa-2x pull-left"), 
                "This application uses a Random Forest regression model to forecast the following day's peak 8-hour ozone concentration based on persistence, forecasted meteorology, and NOAA air quality model outputs.")
            )
          ),
          column(width = 8,
            box(
              title = "Site Context Map", width = NULL, status = "primary", solidHeader = TRUE,
              leafletOutput("about_map", height = "500px")
            )
          )
        )
      )
    )
  )
)

# --- SERVER ---
server <- function(input, output, session) {
  # Reactive Site Config
  site_cfg <- reactive({
    req(input$site_select)
    resolve_site_paths(SITES_CONFIG[[input$site_select]], input$site_select)
  })

  # Update site list based on region
  observe({
    req(input$region_select)
    region_sites <- names(SITES_CONFIG)[sapply(SITES_CONFIG, function(x) x$region == input$region_select)]
    updateSelectInput(session, "site_select", choices = region_sites)
  })

  # Reactive values to trigger UI updates
  v <- reactiveValues(
    data = NULL,
    model = NULL,
    sync_trigger = 0
  )

  # Load data and model when site changes
  observeEvent(input$site_select, {
    cfg <- site_cfg()
    if (file.exists(cfg$data_file)) {
      v$data <- read_csv(cfg$data_file, show_col_types = FALSE)
    } else {
      v$data <- NULL
    }

    if (file.exists(cfg$model_file)) {
      v$model <- readRDS(cfg$model_file)
    } else {
      v$model <- NULL
    }
  })

  # 1.1 Reactive Forecast Calculation (Today)
  forecast_today <- reactive({
    req(input$site_select)
    cfg <- site_cfg()
    v$sync_trigger

    withProgress(message = paste("Fetching Today's Data for", input$site_select, "..."), value = 0.5, {
      target_dt <- Sys.Date()

      # Today's persistence (Real-time)
      today_o3 <- get_latest_o3(cfg$aqs_id)

      # NOAA AQM for TODAY (issued yesterday 12z or today 06z)
      aqm06_reg <- get_aqm(cfg$lat, cfg$lon, target_dt, "06", FALSE)
      aqm06_bc <- get_aqm(cfg$lat, cfg$lon, target_dt, "06", TRUE)
      aqm12_reg <- get_aqm(cfg$lat, cfg$lon, target_dt, "12", FALSE)
      aqm12_bc <- get_aqm(cfg$lat, cfg$lon, target_dt, "12", TRUE)

      # RF Prediction for today (Check history log for entry with Target_Date = Today)
      history <- history_data()
      rf_today <- NA
      issued_dt <- as.character(Sys.Date() - 1)

      if (nrow(history) > 0) {
        # Standardize to character for reliable lookup
        match_idx <- which(as.character(as.Date(history$Target_Date)) == as.character(target_dt))
        if (length(match_idx) > 0) {
          rf_today <- history$RF_Pred[match_idx[1]]
          issued_dt <- as.character(history$Run_Date[match_idx[1]])
        }
      }

      tibble(
        Source = c("Real-time O3 (Latest Hourly)", "RF Prediction (Issued Previously)", "AQM 12z Reg", "AQM 12z BC", "AQM 06z Reg", "AQM 06z BC"),
        Value_ppm = c(today_o3, rf_today, aqm12_reg$val, aqm12_bc$val, aqm06_reg$val, aqm06_bc$val),
        Issued_Date = c(as.character(Sys.Date()), issued_dt, as.character(aqm12_reg$date), as.character(aqm12_bc$date), as.character(aqm06_reg$date), as.character(aqm06_bc$date))
      )
    })
  })

  output$forecast_table_today <- DT::renderDT({
    df <- forecast_today()
    req(df)

    brks <- c(0.054, 0.070, 0.085, 0.105, 0.200)
    clrs <- c("#dff0d8", "#fcf8e3", "#f2dede", "#ebcccc", "#f5e79e", "#e0b0ff")

    DT::datatable(df,
      colnames = c("Source", "Value (ppm)", "Issued Date"),
      options = list(dom = "t", paging = FALSE),
      selection = "none", rownames = FALSE
    ) %>%
      DT::formatStyle("Value_ppm", backgroundColor = DT::styleInterval(brks, clrs)) %>%
      DT::formatRound("Value_ppm", 4)
  })

  output$history_table <- DT::renderDT({
    df <- history_data()
    req(df)

    # Standard columns and display names
    cols_display <- c(
      "Run_Date" = "Run Date",
      "Target_Date" = "Target Date",
      "Observed_O3" = "Observed O3",
      "RF_Pred" = "RF Prediction",
      "AQM_06_Reg" = "AQM 06z Reg",
      "AQM_06_BC" = "AQM 06z BC",
      "AQM_12_Reg" = "AQM 12z Reg",
      "AQM_12_BC" = "AQM 12z BC",
      "Met_Temp_F" = "Temp (F)",
      "Met_Dewp_F" = "Dewp (F)",
      "Met_WS_kts" = "Wind (kts)",
      "Met_WD_deg" = "Wind Dir",
      "Forecast_Type" = "Type"
    )

    # For seasonal sites, only display Mid-February through October 31st
    cfg <- site_cfg()
    if (cfg$seasonal) {
      df <- df %>%
        filter(
          (month(as.Date(Target_Date)) > 2 & month(as.Date(Target_Date)) <= 10) |
            (month(as.Date(Target_Date)) == 2 & day(as.Date(Target_Date)) >= 15)
        )
    }

    df <- df %>% select(any_of(names(cols_display)))
    names(df) <- cols_display[names(df)]

    brks <- c(0.054, 0.070, 0.085, 0.105, 0.200)
    clrs <- c("#dff0d8", "#fcf8e3", "#f2dede", "#ebcccc", "#f5e79e", "#e0b0ff")

    # Column names for formatting
    o3_cols <- c("Observed O3", "RF Prediction", "AQM 06z Reg", "AQM 06z BC", "AQM 12z Reg", "AQM 12z BC")

    DT::datatable(df,
      options = list(pageLength = 10, scrollX = TRUE, order = list(list(0, "desc"))),
      selection = "none", rownames = FALSE
    ) %>%
      DT::formatStyle(o3_cols, backgroundColor = DT::styleInterval(brks, clrs)) %>%
      DT::formatStyle("Temp (F)", backgroundColor = DT::styleInterval(c(40, 60, 80, 95), c("#b3cde3", "#decbe4", "#fed9a6", "#fbb4ae", "#e31a1c"))) %>%
      DT::formatStyle("Dewp (F)", backgroundColor = DT::styleInterval(c(30, 50, 65), c("#ffffcc", "#c2e699", "#78c679", "#238443"))) %>%
      DT::formatRound(o3_cols, 4)
  })

  # 1.2 Reactive Forecast Calculation (Tomorrow)
  forecast_res <- reactive({
    req(input$site_select)
    cfg <- site_cfg()

    # Add dependency on buttons to trigger re-calculation
    v$sync_trigger

    withProgress(message = paste("Calculating Tomorrow's Forecast for", input$site_select, "..."), value = 0.5, {
      target_dt <- Sys.Date() + days(1)

      # RF Prediction for tomorrow (Check if already run today)
      history <- history_data()
      rf_tomorrow <- NA
      if (nrow(history) > 0) {
        match_idx <- which(as.character(as.Date(history$Target_Date)) == as.character(target_dt))
        if (length(match_idx) > 0) rf_tomorrow <- history$RF_Pred[match_idx[1]]
      }

      # NOAA AQM for tomorrow
      aqm06_bc <- get_aqm(cfg$lat, cfg$lon, target_dt, "06", TRUE)
      aqm06_reg <- get_aqm(cfg$lat, cfg$lon, target_dt, "06", FALSE)
      aqm12_bc <- get_aqm(cfg$lat, cfg$lon, target_dt, "12", TRUE)
      aqm12_reg <- get_aqm(cfg$lat, cfg$lon, target_dt, "12", FALSE)

      # Today's O3 (Persistence)
      today_o3 <- get_latest_o3(cfg$aqs_id)
      if (is.na(today_o3) && !is.null(v$data)) {
        today_o3 <- (v$data %>% filter(!is.na(O3)) %>% tail(1))$O3
      }

      # Weather Forecast
      met <- get_nws_forecast(cfg$lat, cfg$lon)

      # RF Prediction
      pred <- NA
      if (!is.null(v$model) && !is.null(v$data)) {
        try(
          {
            # Robust Feature Finding Logic
            get_feat_robust <- function(df, dt, col, name) {
              # 1. Exact Date Match
              val <- (df %>% filter(as.Date(date) == as.Date(dt)))[[col]]
              if (length(val) > 0 && !is.na(val[1])) {
                return(as.numeric(val[1]))
              }

              # 2. Fallback: Latest available non-NA *before* that date
              message(paste("    Note: Missing", name, "for", dt, "- using latest available."))
              fallback <- (df %>% filter(as.Date(date) <= as.Date(dt), !is.na(!!sym(col))) %>% tail(1))[[col]]
              if (length(fallback) > 0) {
                return(as.numeric(fallback[1]))
              }
              return(NA)
            }

            # Construct input row with robust features
            target_dt <- Sys.Date() + days(1)
            input_row <- tibble(
              O3 = if (!is.na(today_o3)) today_o3 else get_feat_robust(v$data, Sys.Date(), "O3", "O3 (today)"),
              O3_lag1 = get_feat_robust(v$data, Sys.Date() - 1, "O3", "O3_lag1"),
              O3_lag2 = get_feat_robust(v$data, Sys.Date() - 2, "O3", "O3_lag2"),
              max_temp_f = get_feat_robust(v$data, Sys.Date(), "max_temp_f", "max_temp_f"),
              min_dewpoint_f = get_feat_robust(v$data, Sys.Date(), "min_dewpoint_f", "min_dewpoint_f"),
              ws = get_feat_robust(v$data, Sys.Date(), "ws", "ws"),
              wd = get_feat_robust(v$data, Sys.Date(), "wd", "wd"),
              max_temp_f_lag1 = get_feat_robust(v$data, Sys.Date() - 1, "max_temp_f", "max_temp_f_lag1"),
              min_dewpoint_f_lag1 = get_feat_robust(v$data, Sys.Date() - 1, "min_dewpoint_f", "min_dewpoint_f_lag1"),
              ws_lag1 = get_feat_robust(v$data, Sys.Date() - 1, "ws", "ws_lag1"),
              wd_lag1 = get_feat_robust(v$data, Sys.Date() - 1, "wd", "wd_lag1"),
              max_temp_f_next = as.numeric(met$max_temp_f),
              min_dewpoint_f_next = as.numeric(met$min_dewpoint_f),
              ws_next = as.numeric(met$ws),
              wd_next = as.numeric(met$wd)
            )

            # Add enhanced features if the model expects them
            model_vars <- rownames(importance(v$model))
            if ("doy" %in% model_vars) input_row$doy <- as.numeric(format(target_dt, "%j"))
            if ("is_weekend" %in% model_vars) input_row$is_weekend <- as.numeric(weekdays(target_dt) %in% c("Saturday", "Sunday"))
            if ("td_spread" %in% model_vars) input_row$td_spread <- as.numeric(input_row$max_temp_f) - as.numeric(input_row$min_dewpoint_f)

            # Final check: RF predict fails if any input is NA
            if (any(is.na(input_row))) {
              message("RF Pred Input contains NA values. Prediction skipped.")
              print(input_row)
            } else {
              pred <- predict(v$model, input_row)
            }
          },
          silent = FALSE
        )
      }

      # Build the entry that will be logged (write happens in observer below — keeps reactive pure)
      log_entry <- if (!is.na(pred)) {
        tibble(
          Run_Date = Sys.Date(),
          Target_Date = target_dt,
          RF_Pred = round(as.numeric(pred), 4),
          Observed_O3 = as.numeric(NA),
          AQM_06_Reg = round(as.numeric(aqm06_reg$val), 4),
          AQM_06_BC = round(as.numeric(aqm06_bc$val), 4),
          AQM_12_Reg = round(as.numeric(aqm12_reg$val), 4),
          AQM_12_BC = round(as.numeric(aqm12_bc$val), 4),
          Met_Temp_F = round(as.numeric(met$max_temp_f), 1),
          Met_Dewp_F = round(as.numeric(met$min_dewpoint_f), 1),
          Met_WS_kts = round(as.numeric(met$ws), 1),
          Met_WD_deg = round(as.numeric(met$wd), 0)
        )
      } else {
        NULL
      }

      list(
        pred = pred,
        aqm06_bc = aqm06_bc, aqm06_reg = aqm06_reg,
        aqm12_bc = aqm12_bc, aqm12_reg = aqm12_reg,
        met = met, date = target_dt,
        log_entry = log_entry
      )
    })
  })

  # The forecast history log is owned by the pipeline (Ozone_Forecaster.R, run by
  # GitHub Actions twice daily). This app is a read-only consumer of it.
  #
  # It used to upsert its own entry here on every page load. Because the app can
  # be running against an older model than the pipeline's, that silently replaced
  # the operational forecast with a different value for the same
  # (Run_Date, Target_Date) key -- e.g. RF_Pred 0.0484 became 0.0464 for
  # 2026-05-31 -- which corrupted the verification statistics computed from it.
  # The live forecast is still shown in the value boxes and the Tomorrow table;
  # it just no longer overwrites the logged record.

  # UI Outputs
  output$rf_box <- renderValueBox({
    f <- forecast_res()
    info <- get_aqi_info(f$pred)
    valueBox(
      value = if (!is.na(f$pred)) paste(round(f$pred, 4), "ppm") else "N/A",
      subtitle = paste("Tomorrow's RF Forecast:", info$status),
      icon = icon("robot"),
      color = info$color
    )
  })

  output$aqm_box <- renderValueBox({
    f <- forecast_res()
    val <- f$aqm12_bc$val
    info <- get_aqi_info(val)
    valueBox(
      value = if (!is.na(val)) paste(round(val, 4), "ppm") else "N/A",
      subtitle = paste("Tomorrow's AQM Bias-Corr:", info$status),
      icon = icon("cloud-sun"),
      color = info$color
    )
  })

  output$met_box <- renderValueBox({
    f <- forecast_res()
    val <- f$met$max_temp_f
    valueBox(
      value = if (!is.na(val)) paste(round(val, 1), "F") else "N/A",
      subtitle = "Tomorrow's Forecasted High Temp",
      icon = icon("thermometer-half"),
      color = "orange"
    )
  })

  output$forecast_table <- DT::renderDT({
    f <- forecast_res()
    req(f)

    get_date <- function(d) if (!is.null(d) && !is.na(d)) as.character(as.Date(d)) else "N/A"

    df <- data.frame(
      Source = c(
        "Our Random Forest",
        "NOAA AQM 06z (Regular)", "NOAA AQM 06z (Bias-Corr)",
        "NOAA AQM 12z (Regular)", "NOAA AQM 12z (Bias-Corr)"
      ),
      Value_ppm = round(c(
        f$pred,
        f$aqm06_reg$val, f$aqm06_bc$val,
        f$aqm12_reg$val, f$aqm12_bc$val
      ), 4),
      Run_Date = c(
        "Live Prediction",
        get_date(f$aqm06_reg$date), get_date(f$aqm06_bc$date),
        get_date(f$aqm12_reg$date), get_date(f$aqm12_bc$date)
      )
    )

    # Add a Status column to explain the synchronization state
    df$Status <- mapply(function(src, dt) {
      if (src == "Our Random Forest") return("Calculated Now")
      if (dt == "N/A") return("Unavailable")
      if (as.Date(dt) >= Sys.Date()) return("Current Run")
      return("NWS Sync Delay (Falling back to previous run)")
    }, df$Source, df$Run_Date)

    brks <- c(0.054, 0.070, 0.085, 0.105, 0.200)
    clrs <- c("#c3e6cb", "#ffeeba", "#ffdf7e", "#f5c6cb", "#d6a6e4", "#eda2b6")

    DT::datatable(df, 
      colnames = c("Source", "Value (ppm)", "Run Date", "Sync Status"),
      options = list(dom = "t", paging = FALSE, scrollX = TRUE), 
      selection = "none", rownames = FALSE
    ) %>%
      DT::formatStyle("Value_ppm", backgroundColor = DT::styleInterval(brks, clrs)) %>%
      DT::formatStyle(
        "Status",
        color = DT::styleEqual(
          c("Current Run", "Calculated Now", "NWS Sync Delay (Falling back to previous run)", "Unavailable"),
          c("#2ecc71", "#2ecc71", "#e67e22", "#e74c3c")
        ),
        fontWeight = "bold"
      )
  })

  output$trend_plot <- renderPlot({
    req(v$data)
    recent <- v$data %>%
      mutate(date = as.Date(date)) %>%
      filter(date >= Sys.Date() - days(6))

    # Define plot domain (Last 7 days including today)
    plot_start <- Sys.Date() - days(6)
    plot_end <- Sys.Date()

    p <- ggplot(recent, aes(x = date, y = O3)) +
      geom_line(color = "steelblue", linewidth = 1.2) +
      geom_point(aes(color = O3), size = 3) +
      scale_color_gradientn(colors = c("green", "yellow", "orange", "red"), limits = c(0, 0.1)) +
      scale_x_date(
        date_breaks = "1 day", date_labels = "%b %d",
        limits = c(plot_start, plot_end)
      ) +
      labs(title = paste("Recent Ozone Levels for", input$site_select), x = "Date", y = "Max 8-hr Ozone (ppm)") +
      geom_hline(yintercept = 0.070, linetype = "dashed", color = "red", alpha = 0.5) +
      annotate("text", x = plot_end, y = 0.072, label = "NAAQS", color = "red", hjust = 1, size = 3) +
      theme_minimal() +
      theme(legend.position = "none")

    if (nrow(recent) == 0) {
      p <- p + annotate("text",
        x = plot_start + (plot_end - plot_start) / 2, y = 0.04,
        label = "No monitoring data in the last 7 days", size = 5, color = "darkgrey"
      )
    }
    return(p)
  })

  output$importance_plot <- renderPlot({
    req(v$model)
    imp <- as.data.frame(importance(v$model))
    imp$Feature <- rownames(imp)
    ggplot(imp, aes(x = reorder(Feature, `%IncMSE`), y = `%IncMSE`)) +
      geom_bar(stat = "identity", fill = "steelblue") +
      coord_flip() +
      theme_minimal()
  })

  # Reactive for history data
  history_data <- reactive({
    req(input$site_select)
    # Trigger refresh on clicking data sync actions OR if the file on disk changes
    v$sync_trigger
    
    log_file <- site_cfg()$history_file

    # Check modification time to force reactivity if the file was updated in R Studio
    if (file.exists(log_file)) {
      mtime <- file.info(log_file)$mtime
      # This dummy reference to `mtime` makes the reactive depend on the file state
      read_csv(log_file, show_col_types = FALSE) %>%
        mutate(Target_Date = as.Date(Target_Date))
    } else {
      tibble()
    }
  })


  # 6. Model Performance Logic

  # Shared function to calculate metrics with optional categorical assessment
  calculate_metrics <- function(full_data, threshold = NULL) {
    req(full_data)
    
    # Define the subset for continuous metrics (RMSE, etc)
    df_subset <- if (!is.null(threshold)) {
      full_data %>% filter(Observed_O3 >= threshold)
    } else {
      full_data
    }
    
    if (nrow(df_subset) < 1) return(NULL)

    # Function to calculate metrics for a given column vs Observed
    # Values are returned pre-formatted as strings so each metric gets the
    # precision it deserves (counts as integers, ppm to 4dp, percentages to 1dp)
    # instead of one blanket digits= setting for the whole table.
    get_col_stats <- function(col_name) {
      sub_data <- df_subset %>% filter(!is.na(!!sym(col_name)) & !is.na(Observed_O3))
      n_vals <- nrow(sub_data)
      if (n_vals < 1) return(rep("N/A", if (!is.null(threshold)) 11 else 7))

      obs <- sub_data$Observed_O3
      pred <- sub_data[[col_name]]
      obs_sum <- sum(obs)

      # Continuous Metrics (on subset)
      rmse_val <- sprintf("%.4f", Metrics::rmse(obs, pred))
      bias_val <- sprintf("%.4f", mean(pred - obs))
      mae_val <- sprintf("%.4f", Metrics::mae(obs, pred))
      # Normalized Mean Bias / Error (%) — the EPA photochemical model evaluation
      # statistics (Emery et al. 2017). Ozone benchmarks: NMB within +/-15%,
      # NME under 25%. These make bias comparable across sites and seasons.
      nmb_val <- if (obs_sum > 0) sprintf("%.1f", sum(pred - obs) / obs_sum * 100) else "N/A"
      nme_val <- if (obs_sum > 0) sprintf("%.1f", sum(abs(pred - obs)) / obs_sum * 100) else "N/A"
      # cor() is undefined (and warns) when either series is constant.
      r2_val <- if (n_vals >= 2 && sd(obs) > 0 && sd(pred) > 0) {
        sprintf("%.3f", cor(obs, pred)^2)
      } else {
        "N/A"
      }

      res <- c(format(n_vals, big.mark = ","), rmse_val, bias_val, mae_val, nmb_val, nme_val, r2_val)

      # Categorical Metrics (on FULL data)
      if (!is.null(threshold)) {
        # filter for rows where both model AND obs are not NA in the full dataset
        eval_data <- full_data %>% filter(!is.na(!!sym(col_name)) & !is.na(Observed_O3))

        hits <- sum(eval_data$Observed_O3 >= threshold & eval_data[[col_name]] >= threshold, na.rm = TRUE)
        misses <- sum(eval_data$Observed_O3 >= threshold & eval_data[[col_name]] < threshold, na.rm = TRUE)
        fas  <- sum(eval_data$Observed_O3 < threshold & eval_data[[col_name]] >= threshold, na.rm = TRUE)

        pod <- if ((hits + misses) > 0) sprintf("%.2f", hits / (hits + misses)) else "N/A"
        far <- if ((hits + fas) > 0) sprintf("%.2f", fas / (hits + fas)) else "N/A"
        csi <- if ((hits + misses + fas) > 0) sprintf("%.2f", hits / (hits + misses + fas)) else "N/A"

        # Show the raw contingency counts so POD/FAR/CSI can be judged in context
        # (a POD of 1.00 built on 2 events is not the same as one built on 40).
        res <- c(res, paste(hits, misses, fas, sep = " / "), pod, far, csi)
      }

      return(res)
    }

    metrics_list <- c(
      "Sample Size (N)", "RMSE (ppm)", "Mean Bias (ppm)", "MAE (ppm)",
      "NMB (%)", "NME (%)", "R-Squared"
    )
    if (!is.null(threshold)) {
      metrics_list <- c(
        metrics_list, "Hits / Miss / FA", "POD (Hit Rate)",
        "FAR (False Alarm Ratio)", "CSI (Threat Score)"
      )
    }
    
    stats_df <- data.frame(
      Metric = metrics_list,
      RF = get_col_stats("RF_Pred")
    )

    aqm_cols <- list("AQM_06R" = "AQM_06_Reg", "AQM_06BC" = "AQM_06_BC", "AQM_12R" = "AQM_12_Reg", "AQM_12BC" = "AQM_12_BC")
    for (name in names(aqm_cols)) {
      stats_df[[name]] <- get_col_stats(aqm_cols[[name]])
    }
    return(stats_df)
  }

  output$perf_metrics_table <- renderTable({
    calculate_metrics(history_data())
  }, striped = TRUE, bordered = TRUE, spacing = "s", align = "lrrrrr")

  output$perf_metrics_mod <- renderTable({
    calculate_metrics(history_data(), threshold = 0.055)
  }, striped = TRUE, bordered = TRUE, spacing = "s", align = "lrrrrr")

  output$perf_metrics_usg <- renderTable({
    calculate_metrics(history_data(), threshold = 0.071)
  }, striped = TRUE, bordered = TRUE, spacing = "s", align = "lrrrrr")

  output$perf_time_series <- renderPlotly({
    df <- history_data()
    req(df)

    cfg <- site_cfg()
    if (cfg$seasonal) {
      # Remove model lines when there are no observations, except for active forecasts (today/future)
      past_no_obs <- is.na(df$Observed_O3) & (as.Date(df$Target_Date) < Sys.Date())
      df$RF_Pred[past_no_obs] <- NA
      df$AQM_06_Reg[past_no_obs] <- NA
      df$AQM_06_BC[past_no_obs] <- NA
      df$AQM_12_Reg[past_no_obs] <- NA
      df$AQM_12_BC[past_no_obs] <- NA
    }

    # Pad dataset with explicit NA rows across seasonal gaps so Plotly breaks the connection lines
    if (nrow(df) > 1) {
      all_dates <- tibble(Target_Date = as.Date(min(df$Target_Date, na.rm=TRUE):max(df$Target_Date, na.rm=TRUE), origin="1970-01-01"))
      df <- df %>% mutate(Target_Date = as.Date(Target_Date)) %>%
        right_join(all_dates, by = "Target_Date") %>%
        arrange(Target_Date)
    }

    p <- plot_ly(df, x = ~Target_Date) %>%
      add_lines(y = ~Observed_O3, name = "Observed", line = list(color = "black", width = 2), connectgaps = FALSE) %>%
      add_lines(y = ~RF_Pred, name = "RF Prediction", line = list(color = "#3c8dbc", dash = "dash"), connectgaps = FALSE)

    # Add all AQM models if they have data
    if (any(!is.na(df$AQM_06_Reg))) {
      p <- p %>% add_lines(y = ~AQM_06_Reg, name = "AQM 06z Reg", line = list(color = "#e74c3c", width = 1, dash = "dot"))
    }
    if (any(!is.na(df$AQM_06_BC))) {
      p <- p %>% add_lines(y = ~AQM_06_BC, name = "AQM 06z BC", line = list(color = "#c0392b", width = 1.5, dash = "dot"))
    }
    if (any(!is.na(df$AQM_12_Reg))) {
      p <- p %>% add_lines(y = ~AQM_12_Reg, name = "AQM 12z Reg", line = list(color = "#f1c40f", width = 1, dash = "dot"))
    }
    if (any(!is.na(df$AQM_12_BC))) {
      p <- p %>% add_lines(y = ~AQM_12_BC, name = "AQM 12z BC", line = list(color = "#f39c12", width = 1.5, dash = "dot"))
    }

    p %>% layout(
      title = list(text = "Historical Comparison", x = 0),
      yaxis = list(title = "Ozone (ppm)"),
      xaxis = list(title = ""),
      hovermode = "x unified",
      legend = list(orientation = "h", y = -0.2),
      shapes = list(list(
        type = "line", x0 = min(df$Target_Date, na.rm = TRUE), x1 = max(df$Target_Date, na.rm = TRUE),
        y0 = 0.070, y1 = 0.070,
        line = list(color = "rgba(255,0,0,0.5)", width = 1.5, dash = "dash")
      )),
      annotations = list(list(
        x = as.character(max(df$Target_Date, na.rm = TRUE)), y = 0.070, text = "NAAQS",
        showarrow = FALSE, yshift = 10, font = list(size = 10, color = "red")
      ))
    )
  })

  output$perf_scatter <- renderPlotly({
    df <- history_data() %>% filter(!is.na(RF_Pred) & !is.na(Observed_O3))
    req(nrow(df) > 1)

    plot_ly(df,
      x = ~Observed_O3, y = ~RF_Pred, type = "scatter", mode = "markers",
      marker = list(opacity = 0.5, size = 8, color = "#3c8dbc")
    ) %>%
      add_lines(
        x = ~ c(0, max(Observed_O3, na.rm = T)), y = ~ c(0, max(Observed_O3, na.rm = T)),
        line = list(color = "gray", dash = "dash"), name = "1:1 Line", showlegend = F
      ) %>%
      layout(
        title = "RF Prediction vs Observed",
        xaxis = list(title = "Observed O3 (ppm)"),
        yaxis = list(title = "RF Predicted O3 (ppm)"),
        showlegend = FALSE
      )
  })

  output$perf_error_dist <- renderPlotly({
    df <- history_data() %>%
      filter(!is.na(RF_Pred) & !is.na(Observed_O3)) %>%
      mutate(Error = RF_Pred - Observed_O3)
    req(nrow(df) > 1)

    plot_ly(df, x = ~Error, type = "histogram", name = "RF Error", marker = list(color = "#3c8dbc", opacity = 0.7)) %>%
      layout(
        title = "Model Error Distribution (Bias)",
        xaxis = list(title = "Prediction Error (ppm)"),
        yaxis = list(title = "Frequency"),
        bargap = 0.1
      )
  })

  # Master Ecosystem Sync Logic
  observeEvent(input$master_sync, {
    old_wd <- getwd()
    withProgress(message = "Global Ecosystem Sync", value = 0, {
      incProgress(0.1, detail = "Starting Data Sync...")
      tryCatch(
        {
          # Run the pipeline scripts with DATA_DIR as the working directory so they
          # read and write the same files the web dashboard and GitHub Actions use.
          setwd(DATA_DIR)

          source("Ozone_Data_Manager.R", local = TRUE)
          for (s in names(SITES_CONFIG)) try(update_site_data(s), silent = TRUE)

          incProgress(0.4, detail = "Training Models...")
          source("Ozone_Model_Training.R", local = TRUE)
          for (s in names(SITES_CONFIG)) try(train_site_model(s), silent = TRUE)

          incProgress(0.3, detail = "Generating Forecasts...")
          source("Ozone_Forecaster.R", local = TRUE)
          for (s in names(SITES_CONFIG)) try(run_forecast(s), silent = TRUE)

          setwd(old_wd)

          # Trigger reloads (site_cfg() resolves to absolute DATA_DIR paths)
          cfg <- site_cfg()
          if (file.exists(cfg$data_file)) {
            v$data <- read_csv(cfg$data_file, show_col_types = FALSE)
          }
          if (file.exists(cfg$model_file)) {
            v$model <- readRDS(cfg$model_file)
          }
          v$sync_trigger <- v$sync_trigger + 1

          incProgress(0.2, detail = "Sync Complete!")
          showNotification("Global Ecosystem Sync Successful!", type = "message")
        },
        error = function(e) {
          showNotification(paste("Sync Failed:", e$message), type = "error")
        },
        finally = setwd(old_wd)
      )
    })
  })

  output$sidebar_map <- renderLeaflet({
    cfg <- site_cfg()
    leaflet() %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      setView(lng = cfg$lon, lat = cfg$lat, zoom = 10) %>%
      addMarkers(lng = cfg$lon, lat = cfg$lat, popup = paste(input$site_select, "\n(AQS:", cfg$aqs_id, ")"))
  })

  output$sidebar_site_name <- renderText({
    input$site_select
  })

  output$about_site_ui <- renderUI({
    cfg <- site_cfg()
    tagList(
      tags$table(class = "table table-striped",
        tags$tbody(
          tags$tr(tags$td(strong("Station Name:")), tags$td(input$site_select)),
          tags$tr(tags$td(strong("Network Region:")), tags$td(cfg$region)),
          tags$tr(tags$td(strong("System AQS ID:")), tags$td(cfg$aqs_id)),
          tags$tr(tags$td(strong("Monitor Schedule:")), tags$td(if (cfg$seasonal) "Seasonal (Mar-Oct)" else "Year-Round")),
          tags$tr(tags$td(strong("Latitude:")), tags$td(cfg$lat)),
          tags$tr(tags$td(strong("Longitude:")), tags$td(cfg$lon)),
          tags$tr(tags$td(strong("Met Data Source:")), tags$td(paste("ASOS Station", cfg$asos)))
        )
      )
    )
  })

  output$about_map <- renderLeaflet({
    cfg <- site_cfg()
    leaflet() %>%
      addProviderTiles(providers$Esri.WorldImagery) %>%
      addProviderTiles(providers$CartoDB.PositronOnlyLabels) %>%
      setView(lng = cfg$lon, lat = cfg$lat, zoom = 15) %>%
      addMarkers(lng = cfg$lon, lat = cfg$lat, popup = paste("<b>", input$site_select, "</b><br>AQS:", cfg$aqs_id))
  })

  output$data_rows_box <- renderInfoBox({
    val <- if (is.null(v$data)) 0 else nrow(v$data)
    infoBox("Total Records", format(val, big.mark=","), icon = icon("database"), color = "light-blue")
  })

  output$data_date_box <- renderInfoBox({
    d <- if (is.null(v$data)) "N/A" else as.character(max(v$data$date, na.rm = T))
    infoBox("Latest Observation", d, icon = icon("calendar-check"), color = "purple")
  })

  output$data_status_box <- renderInfoBox({
    if (is.null(v$data)) {
      infoBox("Sync Status", "Missing", icon = icon("times-circle"), color = "red")
    } else {
      max_date <- max(v$data$date, na.rm = T)
      if (max_date >= Sys.Date() - 1) {
        infoBox("Sync Status", "Up to Date", icon = icon("check-circle"), color = "green")
      } else {
        infoBox("Sync Status", paste(Sys.Date() - max_date, "Days Behind"), icon = icon("exclamation-triangle"), color = "yellow")
      }
    }
  })

  output$data_start_box <- renderInfoBox({
    d <- if (is.null(v$data)) "N/A" else as.character(min(v$data$date, na.rm = T))
    infoBox("Training Hub Since", d, icon = icon("history"), color = "navy")
  })

  output$data_exp_box <- renderInfoBox({
    if (is.null(v$data)) {
      infoBox("Model Experience", "0 Years", icon = icon("award"), color = "yellow")
    } else {
      years <- round(as.numeric(difftime(max(v$data$date, na.rm=T), min(v$data$date, na.rm=T), units="days")) / 365, 1)
      infoBox("Model Experience", paste(years, "Years"), icon = icon("award"), color = "yellow")
    }
  })

  output$data_site_box <- renderInfoBox({
    if (is.null(v$data)) {
      infoBox("Data Completeness", "0%", icon = icon("chart-pie"), color = "orange")
    } else {
      pct <- round(sum(!is.na(v$data$O3)) / nrow(v$data) * 100, 0)
      infoBox("Data Completeness", paste0(pct, "%"), icon = icon("chart-pie"), color = "orange")
    }
  })

  output$data_preview_table <- DT::renderDT({
    req(v$data)
    df <- v$data %>% arrange(desc(date)) %>% head(5)
    DT::datatable(df, options = list(dom = "t", scrollX = TRUE), rownames = FALSE, selection = "none") %>%
      formatRound(c("O3", "max_temp_f", "min_dewpoint_f", "ws", "wd"), 3)
  })

  output$sidebar_status <- renderUI({
    if (is.null(v$data)) return(span(class = "label label-danger", "Status: No Data Found"))
    max_d <- max(v$data$date, na.rm = T)
    if (max_d >= Sys.Date() - 1) {
      span(class = "label label-success", "Status: Data Up to Date")
    } else {
      span(class = "label label-warning", "Status: Sync Recommended")
    }
  })

  output$model_status_label <- renderUI({
    req(input$site_select)
    cfg <- site_cfg()
    if (!file.exists(cfg$model_file)) return(span(class = "label label-danger", "Action: Train Required", style="font-size: 1.1em;"))

    # Check if data file is newer than model file
    m_time <- file.info(cfg$model_file)$mtime
    d_time <- file.info(cfg$data_file)$mtime

    # Using a 2-minute buffer to avoid false alarms during sequential sync
    if (d_time > (m_time + 120)) {
       span(class = "label label-warning", "Action: Retrain Recommended (New Data)", style="font-size: 1.1em;")
    } else {
       span(class = "label label-success", "Status: Model Optimized", style="font-size: 1.1em;")
    }
  })

  output$metrics_text <- renderText({
    req(v$model)
    oob_rmse <- round(sqrt(tail(v$model$mse, 1)), 4)
    oob_rsq  <- round(tail(v$model$rsq, 1), 3)
    paste0("OOB Performance:  RMSE = ", oob_rmse, " ppm  |  R² = ", oob_rsq)
  })

  # Actions
  observeEvent(input$update_btn, {
    req(input$site_select)
    showNotification(paste("Updating data for", input$site_select, "..."), duration = NULL, id = "upd")
    old_wd <- getwd()
    try({
      # source the Data Manager and call the function (inside DATA_DIR)
      setwd(DATA_DIR)
      source("Ozone_Data_Manager.R", local = TRUE)
      update_site_data(input$site_select)
      setwd(old_wd)

      # refresh reactive value
      cfg <- site_cfg()
      v$data <- read_csv(cfg$data_file, show_col_types = F)
      v$sync_trigger <- v$sync_trigger + 1

      removeNotification("upd")
      showNotification("Data Update Complete!", type = "message")
    })
    setwd(old_wd)
  })

  observeEvent(input$retrain_btn, {
    req(input$site_select)
    showNotification(paste("Retraining model for", input$site_select, "..."), duration = NULL, id = "train")
    old_wd <- getwd()
    try({
      # source the Training script and call the function (inside DATA_DIR)
      setwd(DATA_DIR)
      source("Ozone_Model_Training.R", local = TRUE)
      train_site_model(input$site_select)
      setwd(old_wd)

      # refresh reactive value
      cfg <- site_cfg()
      v$model <- readRDS(cfg$model_file)

      removeNotification("train")
      showNotification("Model Retrained!", type = "message")
    })
    setwd(old_wd)
  })
}

shinyApp(ui, server)
