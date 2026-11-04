# Recover_Overwritten_Forecasts.R -- read real forecasts back out of git history.
#
#   Rscript r-pipeline/tools/Recover_Overwritten_Forecasts.R [out.csv]
#
# Until 2026-08-22 (commit e2d6110) the gap filler rewrote every operational
# forecast as a hindcast as soon as its observation arrived, so the history logs
# hold hindcasts for those days. Each run had already committed its log, though,
# so the real forecasts survive in earlier versions of history_<site>.csv.
#
# This walks those versions, keeps each forecast's last version from before its
# observation arrived, and scores it. It prints to the console and changes
# nothing; the recovered rows are written only if you name an output file.
#
#   - The first table scores real forecasts against hindcasts on identical days,
#     Jul 29 - Aug 21, with NOAA and persistence on the same rows.
#   - The second adds them to the operational rows through Oct 31, the sample
#     Operational_Audit.R scores, because that sample starts on Aug 22 only
#     because that is when the bug was fixed.
#   - Rows for Aug 22 - 24 double as a check: the log kept those, so what this
#     recovers for them must match the log.
#
# Needs the full history, so not a shallow clone, and takes a minute or two.
# Intervals come from random draws, so they can differ from the MARAMA deck by a
# few hundredths. Observations are preliminary until AQS certifies them.

suppressMessages({ library(readr); library(dplyr) })

args <- commandArgs(TRUE)
OUT_FILE   <- if (length(args) >= 1) normalizePath(args[1], mustWork = FALSE) else NA
FIRST      <- as.Date("2026-07-29")   # The first target day logged with a provenance tag
LAST       <- as.Date("2026-08-21")   # The last target day the gap filler overwrote
CHECK_LAST <- as.Date("2026-08-24")   # Rows after LAST that the log kept
SEASON_END <- as.Date("2026-10-31")
BOOT_DRAWS <- 5000

here <- normalizePath(dirname(sub("^--file=", "",
  grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
setwd(file.path(here, ".."))
source("sites_config.R")

if (identical(system2("git", c("rev-parse", "--is-shallow-repository"), stdout = TRUE), "true")) {
  stop("This is a shallow clone, so the old logs are not here. Run: git fetch --unshallow")
}

sites <- names(SITES_CONFIG)
log_file <- function(name) paste0("history_", gsub(" ", "_", name), ".csv")

# Oldest first, so a later version of a forecast replaces an earlier one.
commits <- system2("git", c("log", "--reverse", "--format=%h", "--since=2026-07-27",
                            "--until=2026-08-26", "--", log_file(sites[1])), stdout = TRUE)
cat(sprintf("Reading %d saved versions of %d logs...\n", length(commits), length(sites)))

is_blank <- function(x) is.na(x) | x == "" | x == "NA"
found <- list()
for (commit in commits) {
  for (name in sites) {
    lines <- suppressWarnings(system2("git", c("show", paste0(commit, ":./", log_file(name))),
                                      stdout = TRUE, stderr = FALSE))
    if (length(lines) < 2) next
    d <- read.csv(text = lines, colClasses = "character")
    if (!"Forecast_Type" %in% names(d)) next
    # No observation yet means the gap filler had not reached this row.
    d <- d[d$Forecast_Type %in% "operational" & !is_blank(d$RF_Pred) & is_blank(d$Observed_O3), ]
    for (i in seq_len(nrow(d))) {
      target <- as.Date(d$Target_Date[i])
      if (target < FIRST || target > CHECK_LAST || as.Date(d$Run_Date[i]) >= target) next
      found[[paste(name, target)]] <- tibble(site = name, Target_Date = target, rf_recovered = as.numeric(d$RF_Pred[i]))
    }
  }
}
recovered <- bind_rows(found)

all <- bind_rows(lapply(sites, function(name) {
  read_csv(log_file(name), show_col_types = FALSE) %>%
    mutate(site = name, Target_Date = as.Date(Target_Date))
}))
persistence <- all %>%
  filter(!is.na(Observed_O3)) %>%
  group_by(site, Target_Date) %>%
  summarise(Persist = first(Observed_O3), .groups = "drop") %>%
  mutate(Target_Date = Target_Date + 1)
all <- all %>% left_join(persistence, by = c("site", "Target_Date"))

check <- recovered %>%
  filter(Target_Date > LAST) %>%
  inner_join(all, by = c("site", "Target_Date"))
cat(sprintf("Check: %d of %d rows the log kept match what was recovered.\n",
            sum(abs(check$rf_recovered - check$RF_Pred) < 1e-6), nrow(check)))

same_days <- recovered %>%
  filter(Target_Date <= LAST) %>%
  inner_join(all %>% filter(Forecast_Type %in% "hindcast"), by = c("site", "Target_Date")) %>%
  rename(Hindcast = RF_Pred, RF_Pred = rf_recovered) %>%
  filter(!is.na(Observed_O3), !is.na(Hindcast), !is.na(AQM_12_BC), !is.na(AQM_06_BC), !is.na(Persist))
if (nrow(same_days) == 0) stop("Nothing recovered.")

rmse <- function(p, o) sqrt(mean((p - o)^2)) * 1000
score_table <- function(d, models, label) {
  cat(sprintf("\n=== %s (n=%d, %d days) ===\n", label, nrow(d), n_distinct(d$Target_Date)))
  for (k in names(models)) {
    p <- d[[models[k]]]
    cat(sprintf("%-22s RMSE %5.2f ppb   bias %+5.2f   R2 %.2f\n", k, rmse(p, d$Observed_O3),
                mean(p - d$Observed_O3) * 1000, cor(p, d$Observed_O3)^2))
  }
}
# Resampling a day takes all of its site rows, so each day's squared-error sums
# are all the bootstrap needs.
boot_gap <- function(d, ref) {
  per_day <- d %>% group_by(Target_Date) %>%
    summarise(n = n(), a = sum((RF_Pred - Observed_O3)^2),
              b = sum((.data[[ref]] - Observed_O3)^2), .groups = "drop")
  g <- replicate(BOOT_DRAWS, {
    i <- sample.int(nrow(per_day), replace = TRUE)
    (sqrt(sum(per_day$a[i]) / sum(per_day$n[i])) - sqrt(sum(per_day$b[i]) / sum(per_day$n[i]))) * 1000
  })
  cat(sprintf("Real RF - %-9s %+5.2f ppb  95%% interval [%+5.2f, %+5.2f]\n", ref, mean(g),
              quantile(g, .025), quantile(g, .975)))
}

set.seed(1)
score_table(same_days, c("RF real forecast" = "RF_Pred", "RF hindcast" = "Hindcast",
                         "NOAA 12z BC" = "AQM_12_BC", "NOAA 06z BC" = "AQM_06_BC",
                         "Persistence" = "Persist"), "SAME DAYS")
cat(sprintf("Real forecast error is %.1f times the hindcast's.\n",
            rmse(same_days$RF_Pred, same_days$Observed_O3) / rmse(same_days$Hindcast, same_days$Observed_O3)))
boot_gap(same_days, "Hindcast")

keep <- c("site", "Target_Date", "Observed_O3", "RF_Pred", "AQM_12_BC", "AQM_06_BC", "Persist")
kept <- all %>%
  filter(Forecast_Type %in% "operational", Target_Date <= SEASON_END,
         !is.na(Observed_O3), !is.na(RF_Pred), !is.na(AQM_12_BC), !is.na(AQM_06_BC),
         !is.na(AQM_06_Reg), !is.na(AQM_12_Reg), !is.na(Persist))
combined <- bind_rows(same_days %>% select(all_of(keep)), kept %>% select(all_of(keep)))
score_table(combined, c("Random forest" = "RF_Pred", "NOAA 12z BC" = "AQM_12_BC",
                        "NOAA 06z BC" = "AQM_06_BC", "Persistence" = "Persist"),
            "RECOVERED PLUS THE OPERATIONAL LOG")
for (ref in c("AQM_06_BC", "AQM_12_BC", "Persist")) boot_gap(combined, ref)

if (!is.na(OUT_FILE)) {
  same_days %>%
    arrange(Target_Date, site) %>%
    transmute(site = gsub(" ", "_", site), target_date = Target_Date, observed_o3 = Observed_O3,
              rf_real_forecast = RF_Pred, rf_hindcast = Hindcast, aqm_12_bc = AQM_12_BC,
              aqm_06_bc = AQM_06_BC, persistence = Persist) %>%
    write_csv(OUT_FILE)
  cat(sprintf("\nWrote %d rows to %s\n", nrow(same_days), OUT_FILE))
}
