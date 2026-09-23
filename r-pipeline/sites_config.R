# sites_config.R - Monitoring Site Metadata for Mississippi Ozone App

SITES_CONFIG <- list(
    "Hernando" = list(
        region = "DeSoto",
        aqs_id = "28-033-0002",
        state = "28",
        county = "033",
        site = "0002",
        lat = 34.82,
        lon = -89.99,
        asos = "MEM",
        data_file = "aq_MetDaily_Hernando.csv",
        model_file = "model_Hernando.rds",
        seasonal = TRUE
    ),
    "Jackson NCORE" = list(
        region = "Jackson",
        aqs_id = "28-049-0020",
        state = "28",
        county = "049",
        site = "0020",
        lat = 32.33,
        lon = -90.18,
        asos = "JAN",
        data_file = "aq_MetDaily_Jackson_NCORE.csv",
        model_file = "model_Jackson_NCORE.rds",
        seasonal = FALSE
    ),
    "Hinds CC" = list(
        region = "Jackson",
        aqs_id = "28-049-0021",
        state = "28",
        county = "049",
        site = "0021",
        lat = 32.35,
        lon = -90.23,
        asos = "JAN",
        data_file = "aq_MetDaily_Hinds_CC.csv",
        model_file = "model_Hinds_CC.rds",
        seasonal = TRUE
    ),
    "Waveland" = list(
        region = "Coast",
        aqs_id = "28-045-0003",
        state = "28",
        county = "045",
        site = "0003",
        lat = 30.300917,
        lon = -89.395954,
        asos = "GPT",
        data_file = "aq_MetDaily_Waveland.csv",
        model_file = "model_Waveland.rds",
        seasonal = TRUE
    ),
    "Gulfport" = list(
        region = "Coast",
        aqs_id = "28-047-0008",
        state = "28",
        county = "047",
        site = "0008",
        lat = 30.37,
        lon = -89.09,
        asos = "GPT",
        data_file = "aq_MetDaily_Gulfport.csv",
        model_file = "model_Gulfport.rds",
        seasonal = TRUE
    ),
    "Pascagoula" = list(
        region = "Coast",
        aqs_id = "28-059-0006",
        state = "28",
        county = "059",
        site = "0006",
        lat = 30.37,
        lon = -88.54,
        asos = "GPT",
        data_file = "aq_MetDaily_Pascagoula.csv",
        model_file = "model_Pascagoula.rds",
        seasonal = TRUE
    )
)

# --- Ozone season (sites with seasonal = TRUE) ---
# Mississippi's ozone monitoring season is March 1 - October 31, both days
# included (40 CFR 58 Appendix D, Table D-3). Forecasts are issued, shown and
# verified only for target dates in this window. Written as "MM-DD".
OZONE_SEASON_START <- "03-01"
OZONE_SEASON_END   <- "10-31"

# Look-back buffer. The seasonal monitors start up two weeks before the season,
# and their readings are kept from then on, so the lag features and the 14-day
# gap-fill windows already hold real data when the first in-season forecast is
# issued (on Feb 28, for Mar 1). Any reading before this date (from Nov 1 on) is
# phantom and is discarded. Counted on a common-year calendar, so it is Feb 15
# every year (in a leap year, Mar 1 minus 14 days would be Feb 16).
OZONE_DATA_LEAD_DAYS <- 14
OZONE_DATA_START <- format(as.Date(paste0("2001-", OZONE_SEASON_START)) - OZONE_DATA_LEAD_DAYS, "%m-%d")

# TRUE for dates in the ozone season (Mar 1 - Oct 31). Vectorised.
in_ozone_season <- function(d) {
  md <- format(as.Date(d), "%m-%d")
  md >= OZONE_SEASON_START & md <= OZONE_SEASON_END
}

# TRUE for dates a seasonal monitor is running: the look-back buffer plus the
# season (Feb 15 - Oct 31). Vectorised.
in_monitor_window <- function(d) {
  md <- format(as.Date(d), "%m-%d")
  md >= OZONE_DATA_START & md <= OZONE_SEASON_END
}
