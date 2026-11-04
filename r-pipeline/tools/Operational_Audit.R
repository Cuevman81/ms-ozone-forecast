# Operational_Audit.R -- score the forecasts this system actually issued.
#
#   Rscript r-pipeline/tools/Operational_Audit.R [through] [era_start]
#
#   through    last target date to score, e.g. 2026-10-31. Default: everything.
#   era_start  split the sample at runs from this date, e.g. the day a fix went
#              in. Default: 2026-09-23, MDEQ's wind and training-window fixes.
#
# Prints to the console and writes nothing. It reads history_<site>.csv for
# every site in sites_config.R, so a fork needs no changes.
#
# The rules, which are the whole point:
#   - Forecast_Type == "operational" rows only. Hindcast rows used the observed
#     weather (see "Reading the verification statistics" in the README).
#   - Every model is scored on exactly the same rows.
#   - Persistence = the observed max 8-hour ozone on the day before the target.
#   - RF-vs-reference gaps come with a bootstrap that resamples whole target
#     days, because sites on the same day are not independent.
#
# Reproduce the numbers in the 2026 MARAMA talk (season ending Oct 31):
#   Rscript r-pipeline/tools/Operational_Audit.R 2026-10-31
# Late-season observations are preliminary AirNow values until AQS certifies
# them, so a later run can differ slightly.

suppressMessages({ library(readr); library(dplyr) })

args <- commandArgs(TRUE)
THROUGH   <- if (length(args) >= 1) as.Date(args[1]) else as.Date("2100-01-01")
ERA_START <- as.Date(if (length(args) >= 2) args[2] else "2026-09-23")
MODERATE  <- 0.055
USG       <- 0.071
BOOT_DRAWS <- 5000

here <- normalizePath(dirname(sub("^--file=", "",
  grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
setwd(file.path(here, ".."))
source("sites_config.R")

read_site <- function(name) {
  d <- read_csv(paste0("history_", gsub(" ", "_", name), ".csv"), show_col_types = FALSE) %>%
    mutate(site = name, Target_Date = as.Date(Target_Date), Run_Date = as.Date(Run_Date))
  # The dashboard shows and verifies the ozone season only, as export_json.R does.
  if (isTRUE(SITES_CONFIG[[name]]$seasonal)) d <- d %>% filter(in_ozone_season(Target_Date))
  d
}
all <- bind_rows(lapply(names(SITES_CONFIG), read_site))

persistence <- all %>%
  filter(!is.na(Observed_O3)) %>%
  group_by(site, Target_Date) %>%
  summarise(Persist = first(Observed_O3), .groups = "drop") %>%
  mutate(Target_Date = Target_Date + 1)
all <- all %>% left_join(persistence, by = c("site", "Target_Date"))

op <- all %>%
  filter(Forecast_Type %in% "operational", Target_Date <= THROUGH,
         !is.na(Observed_O3), !is.na(RF_Pred))
if (nrow(op) == 0) stop("No scorable operational rows yet.")

MODELS <- c(RF = "RF_Pred", AQM06 = "AQM_06_Reg", AQM06BC = "AQM_06_BC",
            AQM12 = "AQM_12_Reg", AQM12BC = "AQM_12_BC", Persist = "Persist")
paired <- op %>% filter(if_all(all_of(unname(MODELS)), ~ !is.na(.)))

cat("=== SAMPLE ===\n")
cat(sprintf("operational rows scorable: %d, on all models: %d, targets %s to %s\n",
            nrow(op), nrow(paired), min(op$Target_Date), max(op$Target_Date)))
print(table(paired$site))
cat(sprintf("target days: %d   Moderate+ (>= 55 ppb): %d   USG+ (>= 71 ppb): %d\n",
            n_distinct(paired$Target_Date), sum(paired$Observed_O3 >= MODERATE),
            sum(paired$Observed_O3 >= USG)))

# POD, FAR and CSI at the Moderate threshold, over every paired row.
score <- function(o, p, thr = MODERATE) {
  h <- sum(o >= thr & p >= thr); m <- sum(o >= thr & p < thr); f <- sum(o < thr & p >= thr)
  c(RMSE = sqrt(mean((p - o)^2)) * 1000, MAE = mean(abs(p - o)) * 1000, Bias = mean(p - o) * 1000,
    NMB = sum(p - o) / sum(o) * 100, NME = sum(abs(p - o)) / sum(o) * 100, R2 = cor(o, p)^2,
    hits = h, miss = m, FA = f,
    POD = if (h + m > 0) h / (h + m) else NA, FAR = if (h + f > 0) f / (h + f) else NA,
    CSI = if (h + m + f > 0) h / (h + m + f) else NA)
}
score_table <- function(d, label) {
  cat(sprintf("\n=== %s (paired n=%d) ===\n", label, nrow(d)))
  if (nrow(d) < 2) { cat("too few rows\n"); return(invisible(NULL)) }
  cat(sprintf("%-8s %6s %6s %6s %6s %6s %6s | %3s %3s %3s %5s %5s %5s\n",
              "model", "RMSE", "MAE", "Bias", "NMB%", "NME%", "R2", "hit", "mis", "FA", "POD", "FAR", "CSI"))
  for (k in names(MODELS)) {
    s <- score(d$Observed_O3, d[[MODELS[k]]])
    cat(sprintf("%-8s %6.1f %6.1f %+6.1f %+6.1f %6.1f %6.3f | %3d %3d %3d %5.2f %5.2f %5.2f\n",
                k, s["RMSE"], s["MAE"], s["Bias"], s["NMB"], s["NME"], s["R2"],
                as.integer(s["hits"]), as.integer(s["miss"]), as.integer(s["FA"]),
                s["POD"], s["FAR"], s["CSI"]))
  }
}
score_table(paired, "ALL OPERATIONAL")
score_table(paired %>% filter(Run_Date < ERA_START), paste("RUNS BEFORE", ERA_START))
score_table(paired %>% filter(Run_Date >= ERA_START), paste("RUNS FROM", ERA_START))

cat("\n=== PER SITE (RMSE ppb / bias ppb) ===\n")
cat(sprintf("%-14s %4s %13s %13s %13s %13s\n", "site", "n", "RF", "AQM06BC", "AQM12BC", "Persist"))
for (name in names(SITES_CONFIG)) {
  d <- paired %>% filter(site == name)
  if (nrow(d) < 3) next
  cell <- function(m) sprintf("%5.1f / %+5.1f", sqrt(mean((d[[m]] - d$Observed_O3)^2)) * 1000,
                              mean(d[[m]] - d$Observed_O3) * 1000)
  cat(sprintf("%-14s %4d %13s %13s %13s %13s\n", name, nrow(d),
              cell("RF_Pred"), cell("AQM_06_BC"), cell("AQM_12_BC"), cell("Persist")))
}

cat("\n=== BIAS BY OBSERVED LEVEL (ppb) ===\n")
by_level <- paired %>%
  mutate(level = cut(Observed_O3 * 1000, c(0, 35, 45, 55, Inf), right = FALSE,
                     labels = c("under 35", "35-44", "45-54", "55+"))) %>%
  group_by(level) %>%
  summarise(n = n(), RF = mean(RF_Pred - Observed_O3) * 1000,
            AQM06BC = mean(AQM_06_BC - Observed_O3) * 1000,
            AQM12BC = mean(AQM_12_BC - Observed_O3) * 1000,
            Persist = mean(Persist - Observed_O3) * 1000, .groups = "drop")
print(as.data.frame(by_level), digits = 3, row.names = FALSE)

# Resampling a day takes all of its site rows, so each day's squared-error sums
# are all the bootstrap needs. "a" and "b" are the columns compared: a - b.
boot_gap <- function(d, a, b) {
  per_day <- d %>% group_by(Target_Date) %>%
    summarise(n = n(), a = sum((.data[[a]] - Observed_O3)^2),
              b = sum((.data[[b]] - Observed_O3)^2), .groups = "drop")
  g <- replicate(BOOT_DRAWS, {
    i <- sample.int(nrow(per_day), replace = TRUE)
    (sqrt(sum(per_day$a[i]) / sum(per_day$n[i])) - sqrt(sum(per_day$b[i]) / sum(per_day$n[i]))) * 1000
  })
  sprintf("%+5.2f ppb  95%% interval [%+5.2f, %+5.2f]  P(first better) = %.2f",
          mean(g), quantile(g, .025), quantile(g, .975), mean(g < 0))
}
references <- c("AQM_06_BC", "AQM_12_BC", "Persist")

set.seed(1)
cat("\n=== IS THE GAP REAL? RF RMSE minus each reference, resampling whole days ===\n")
for (r in references) cat(sprintf("all runs,   RF - %-9s %s\n", r, boot_gap(paired, "RF_Pred", r)))
later <- paired %>% filter(Run_Date >= ERA_START)
if (n_distinct(later$Target_Date) >= 2) {
  for (r in references) cat(sprintf("from era,   RF - %-9s %s\n", r, boot_gap(later, "RF_Pred", r)))
}

cat("\n=== EQUAL-WEIGHT MEAN OF RF AND NOAA 12z BC (nothing fitted) ===\n")
paired <- paired %>% mutate(Blend = (RF_Pred + AQM_12_BC) / 2)
s <- score(paired$Observed_O3, paired$Blend)
cat(sprintf("RMSE %.1f ppb, CSI %.2f, RF and 12z BC error correlation r = %.2f\n", s["RMSE"], s["CSI"],
            cor(paired$RF_Pred - paired$Observed_O3, paired$AQM_12_BC - paired$Observed_O3)))
cat(sprintf("Blend - AQM_12_BC %s\n", boot_gap(paired, "Blend", "AQM_12_BC")))

cat("\n=== HINDCAST vs OPERATIONAL, same model design, not the same days ===\n")
hc <- all %>% filter(Forecast_Type %in% "hindcast", Target_Date <= THROUGH,
                     !is.na(Observed_O3), !is.na(RF_Pred))
if (nrow(hc) >= 2) {
  cat(sprintf("hindcast    n=%4d  %s to %s  RF RMSE %.1f ppb  R2 %.2f\n", nrow(hc),
              min(hc$Target_Date), max(hc$Target_Date),
              sqrt(mean((hc$RF_Pred - hc$Observed_O3)^2)) * 1000, cor(hc$RF_Pred, hc$Observed_O3)^2))
  cat(sprintf("operational n=%4d  %s to %s  RF RMSE %.1f ppb  R2 %.2f\n", nrow(paired),
              min(paired$Target_Date), max(paired$Target_Date),
              sqrt(mean((paired$RF_Pred - paired$Observed_O3)^2)) * 1000,
              cor(paired$RF_Pred, paired$Observed_O3)^2))
}
