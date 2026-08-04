# MS Ozone Forecast Dashboard

A web-based dashboard for Mississippi's ground-level ozone forecasting system operated by the [Mississippi Department of Environmental Quality (MDEQ)](https://www.mdeq.ms.gov/). The dashboard provides next-day ozone predictions using Random Forest machine learning models, NOAA air quality model comparisons, and real-time monitoring data for 6 sites across the state.

**Live Dashboard:** [ms-ozone-forecast.vercel.app](https://ms-ozone-forecast.vercel.app)

## Monitoring Sites

| Site | Region | AQS ID | Schedule |
|------|--------|--------|----------|
| Hernando | DeSoto (Memphis metro) | 28-033-0002 | Seasonal (Mar–Oct) |
| Jackson NCORE | Jackson | 28-049-0020 | Year-Round |
| Hinds CC | Jackson | 28-049-0021 | Seasonal (Mar–Oct) |
| Waveland | Coast | 28-045-0003 | Seasonal (Mar–Oct) |
| Gulfport | Coast | 28-047-0008 | Seasonal (Mar–Oct) |
| Pascagoula | Coast | 28-059-0006 | Seasonal (Mar–Oct) |

## How It Works

```
r-pipeline/ (scheduled, GitHub Actions)     Static frontend (always on)
┌──────────────────────────────┐            ┌──────────────────────┐
│ Ozone_Data_Manager.R         │            │ index.html           │
│   EPA AQS + AirNow           │            │ Plotly.js charts     │
│   Iowa ASOS weather          │            │ Leaflet.js maps      │
│ Ozone_Model_Training.R       │─ export ──>│ DataTables           │
│   Random Forest              │  (JSON)    │ Deployed on Vercel   │
│ Ozone_Forecaster.R           │            └──────────┬───────────┘
│   NWS + NOAA AQM             │                       │
└──────────────┬───────────────┘            ┌──────────┴───────────┐
               │                            │ api/realtime.js      │
        shiny-app/app.R                     │   live hourly O3     │
         (local, optional)                  └──────────────────────┘
```

`run_pipeline.R` drives the three R scripts, then `export_json.R` converts the
CSVs and `.rds` models into the JSON in `data/` that the dashboard reads. No R
server runs at request time — the deployed site is static files plus one
serverless function for real-time ozone.

The Shiny app in `shiny-app/` is an optional local front end over the same
`r-pipeline/` files. It is not deployed.

## Automated Data Updates

The dashboard data is updated automatically via [GitHub Actions](https://github.com/Cuevman81/ms-ozone-forecast/actions) on two scheduled runs daily:

| Run | Cron (UTC) | Time (Central, DST) | Purpose |
|-----|-----------|--------------------|---------|
| Morning | `30 10 * * *` | **5:30 AM CT** | Fetch overnight observed data, update models, generate initial forecast — after the 06z AQM run lands |
| Midday | `30 16 * * *` | **11:30 AM CT** | Capture the completed 12z NOAA AQM run, refresh forecast with latest data |

Cron is fixed to UTC, so during standard time these land an hour earlier (4:30 AM
and 10:30 AM CT). GitHub also queues scheduled jobs under load, so actual start
times routinely run 30–90 minutes late; the pipeline is written to be idempotent,
so a late or repeated run is harmless.

Each pipeline run performs the following steps in order:

1. **Data Sync** — Fetches the latest daily ozone observations from EPA AQS (with AirNow fallback) and meteorological data from Iowa State ASOS for all 6 sites
2. **Model Training** — Retrains the Random Forest model for any site that has new data since its last training (smart retrain — skips sites with no changes)
3. **Forecasting** — Generates tomorrow's ozone prediction using real-time O3, NWS weather forecasts, and NOAA AQM model outputs. Backfills observed values into past forecast entries for verification
4. **JSON Export** — Converts all CSVs and model outputs to JSON for the web dashboard
5. **Deploy** — Commits updated data to GitHub, which triggers an automatic Vercel redeploy

Real-time hourly ozone is also available live via a serverless function that fetches directly from AirNow — this updates independently of the scheduled pipeline.

The pipeline can also be triggered manually from the [Actions tab](https://github.com/Cuevman81/ms-ozone-forecast/actions/workflows/sync-pipeline.yml) using the "Run workflow" button.

## Model Features

The Random Forest regression model predicts next-day maximum 8-hour ozone concentration using 18 features:

| Category | Features |
|----------|----------|
| **Persistence** | O3 (today), O3_lag1, O3_lag2 |
| **Current meteorology** | max_temp_f, min_dewpoint_f, ws, wd |
| **Lagged meteorology** | max_temp_f_lag1, min_dewpoint_f_lag1, ws_lag1, wd_lag1 |
| **Forecast meteorology** | max_temp_f_next, min_dewpoint_f_next, ws_next, wd_next |
| **Temporal/derived** | doy (day of year), is_weekend, td_spread (temp-dewpoint spread) |

## Dashboard Tabs

- **Dashboard** — Value boxes for RF prediction, AQM bias-corrected forecast, and forecasted high temp. Today and tomorrow forecast comparison tables with AQI color coding and sync status. 7-day ozone trend chart.
- **Trends & Analysis** — Variable importance plot, model control with status and retrain capability, historical time series comparing RF vs observed vs NOAA AQM models (with the 0.070 ppm NAAQS marked), scatter plot, error distribution, and a verification table at overall, Moderate+ and USG+ thresholds:
  - **Continuous:** RMSE, Mean Bias, MAE, NMB %, NME %, R². NMB and NME are the EPA photochemical model evaluation statistics (Emery et al. 2017); the ozone benchmarks are NMB within ±15% and NME under 25%.
  - **Categorical** (threshold tables): raw Hits / Misses / False Alarms, plus POD, FAR and CSI. The counts are shown so the rates can be judged in context — a POD of 1.00 built on 2 events is not the same as one built on 40.
- **Data Management** — Data completeness stats, sync status, and raw data preview.
- **About Station** — Site profile, coordinates, and satellite imagery map.

## Data Sources

- **Ozone observations:** [EPA AQS](https://aqs.epa.gov/aqsweb/documents/data_api.html) with [AirNow](https://www.airnow.gov/) fallback for recent days
- **Meteorology:** [Iowa State ASOS](https://mesonet.agron.iastate.edu/) daily summaries
- **Weather forecasts:** [NWS API](https://www.weather.gov/documentation/services-web-api) gridded forecast data
- **Air quality model:** [NOAA AQMv7](https://www.weather.gov/sti/stimodeling_airquality) (06z/12z cycles, regular and bias-corrected)
- **Real-time O3:** [AirNow S3](https://docs.airnowapi.org/) hourly data files

## Running It Locally

```bash
git clone https://github.com/Cuevman81/ms-ozone-forecast.git
cd ms-ozone-forecast
```

All commands below are run from that directory. There are three things you can
run, and they need increasingly more setup.

### 1. The dashboard — no setup at all

The exported JSON in `data/` is committed, so the dashboard is fully functional
straight out of a clone. Any static file server works:

```bash
python3 -m http.server 8080
# Open http://localhost:8080
```

You get every tab, chart, table, and metric with real data. Only the "Real-time
O3 (Latest Hourly)" row stays `N/A`, because that one value comes from a
serverless function rather than the static files.

### 2. The dev server — adds real-time O3 and sync buttons

Needs **Python 3** (standard library only — nothing to install):

```bash
python3 dev_server.py
# Open http://localhost:8080
```

Over the plain file server this adds:

- **Real-time O3** proxy — fetches the latest hourly value from AirNow
- **Sync & Refresh Ecosystem** — runs the full R pipeline *(needs step 3's setup)*
- **Retrain Model** — retrains the selected site's model *(needs step 3's setup)*

If the port is busy it tries 8081–8089 and prints the one it picked.

### 3. The R pipeline and Shiny app

**Prerequisites**

R 4.4 or newer. The `terra` package needs GDAL, GEOS and PROJ present first —
that is the usual install failure:

```bash
# macOS
brew install gdal geos proj

# Debian / Ubuntu
sudo apt-get install -y libgdal-dev libgeos-dev libproj-dev \
                        libudunits2-dev libcurl4-openssl-dev libssl-dev
```

Then the R packages:

```r
# Pipeline only
install.packages(c("RAQSAPI", "randomForest", "caret", "terra", "httr2",
                   "jsonlite", "dplyr", "readr", "lubridate", "purrr",
                   "tidyr", "ggplot2", "Metrics"))

# Additionally required by the Shiny app
install.packages(c("shiny", "shinydashboard", "bslib", "leaflet",
                   "thematic", "DT", "plotly"))
```

**Credentials**

Only two are actually required: **`AQS_EMAIL`** and **`AQS_KEY`**.
`Ozone_Data_Manager.R` stops immediately without them. Request a free EPA AQS key
via the signup endpoint in the
[AQS API docs](https://aqs.epa.gov/aqsweb/documents/data_api.html#signup) — the
key arrives by email.

Put them in `~/.Renviron` (**not** in the repo) and restart R:

```
AQS_EMAIL=you@example.com
AQS_KEY=yourkeyhere
```

`AIRNOW_API_KEY` appears in the workflow and is read into a variable, but nothing
currently uses it — every AirNow lookup reads the public S3 hourly files
unauthenticated. You do not need one.

Running the fork's own GitHub Actions additionally needs these as repository
secrets under **Settings → Secrets and variables → Actions**.

**Run the pipeline**

```bash
Rscript r-pipeline/run_pipeline.R
```

One step: data sync → model training → forecasts → JSON export. This is the same
entry point the scheduled workflow uses, so a manual run and a scheduled run
produce identical files. Expect several minutes — it downloads GRIB2 model output
for each site. It writes into `r-pipeline/` and `data/`; commit and push to
deploy.

> **The trained models are not in the repository.** `model_<site>.rds` files are
> build artifacts — training is stochastic, so every run produced a byte-different
> multi-megabyte file, and committing them twice a day grew the repo to 1.75 GB
> against a 35 MB working tree. They are gitignored; the command above builds them
> on its first run. Nothing else needs them: the dashboard reads the committed
> JSON in `data/`, `importance.json` included.

**Run the Shiny app**

```bash
Rscript -e 'shiny::runApp("shiny-app")'
```

Or open `shiny-app/app.R` in RStudio and click **Run App**. It reads the
committed data, so it works without credentials — you only need those if you use
its Sync or Retrain buttons.

> If you cloned into an existing project that keeps this repo in a
> `web-dashboard/` subfolder, use `shiny::runApp("web-dashboard/shiny-app")`
> instead. `app.R` locates its data either way.

### Deploying your own copy

The site is static plus one serverless function, so importing the fork into
Vercel works with no build step and no configuration. `vercel.json` sets the
cache and security headers; `.vercelignore` keeps the 32 MB of training data and
the Shiny source out of the deployment.

## Single source of truth

Everything reads and writes **`r-pipeline/`** — the Shiny app, the JSON exporter,
the local dev server, and GitHub Actions. `app.R` resolves `DATA_DIR` to that
folder at startup and takes `sites_config.R` from it too, so there is exactly one
copy of every CSV, model, history log, and the site metadata.

This is deliberate. These files were previously duplicated outside the repo, the
two sets drifted two months apart, and the Shiny app ended up forecasting from a
stale model *and* overwriting the pipeline's logged forecasts with its own.

The pipeline owns `history_<site>.csv`. The Shiny app displays it and never
writes to it.

### Reading the verification statistics

`Forecast_Type` in the history log records how each `RF_Pred` was produced:

- **`operational`** — issued ahead of time from the NWS *forecast* meteorology. A
  real forecast.
- **`hindcast`** — reconstructed later by the retrospective gap-fill using the
  *observed* meteorology for the target day. Perfect prognosis, so it scores far
  better than the model can achieve live.
- **empty** — logged before this column existed; treat as unknown.

Do not pool the two. Most historical RF rows are hindcasts, while every NOAA AQM
value is a genuine forecast, so a combined RF-versus-AQM comparison flatters the
RF considerably.

Similarly, in the **Moderate+** and **USG+** tables the continuous statistics
(RMSE, Bias, NMB, NME, R²) are computed only on days where the *observed* value
cleared the threshold. Conditioning on the observation narrows the remaining
spread, which drives R² toward 0 and bias negative even for a skillful model.
That is a known artifact of conditional verification, not evidence of failure —
judge event performance on POD / FAR / CSI, which are computed over the full
record.

## Project Structure

```
ms-ozone-forecast/      # repo root — this is what you get from git clone
├── index.html          # Main dashboard (4 tabs)
├── css/style.css       # Dashboard styling
├── js/app.js           # Application logic (Plotly, Leaflet, DataTables)
├── dev_server.py       # Local dev server with sync/retrain API
├── export_json.R       # R script: CSV/RDS -> JSON conversion
├── vercel.json         # Cache-control and security headers
├── .vercelignore       # Keeps r-pipeline/ and shiny-app/ out of the deploy
├── api/
│   └── realtime.js     # Serverless function: live hourly O3 from AirNow
├── .github/workflows/
│   └── sync-pipeline.yml   # Twice-daily scheduled pipeline
├── shiny-app/
│   └── app.R           # The R Shiny app (run locally, not deployed)
├── r-pipeline/         # Source of truth: data, models, and pipeline scripts
│   ├── run_pipeline.R      # Entry point used by GitHub Actions
│   ├── sites_config.R      # Site metadata (the only copy)
│   ├── Ozone_Data_Manager.R / _Model_Training.R / _Forecaster.R
│   ├── aq_MetDaily_<site>.csv   # Training data
│   ├── model_<site>.rds         # Trained RF models — NOT in git, built locally
│   └── history_<site>.csv       # Forecast log (pipeline writes, app reads)
└── data/               # Pre-exported JSON (one folder per site)
    ├── sites_config.json
    ├── meta.json
    ├── Hernando/
    │   ├── history.json       # Forecast history log
    │   ├── recent.json        # Last 7 days for trend plot
    │   ├── data_summary.json  # Training data stats
    │   ├── importance.json    # RF variable importance
    │   └── metrics.json       # Model performance metrics
    ├── Jackson_NCORE/
    ├── Hinds_CC/
    ├── Waveland/
    ├── Gulfport/
    └── Pascagoula/
```

## Built With

- **Backend:** R (randomForest, RAQSAPI, terra, httr2)
- **Local app:** R Shiny (shinydashboard, plotly, leaflet, DT)
- **Frontend:** Vanilla HTML/CSS/JS — no build step, no bundler
- **Charts:** [Plotly.js](https://plotly.com/javascript/)
- **Maps:** [Leaflet.js](https://leafletjs.com/)
- **Tables:** [DataTables](https://datatables.net/)
- **Hosting:** [Vercel](https://vercel.com/) (static + one serverless function)
- **Automation:** GitHub Actions

## Maintainer

Rodney Cuevas, Mississippi Department of Environmental Quality —
RCuevas@mdeq.ms.gov

Forecasts published here are decision-support output from a research model, not
an official regulatory determination. For official air quality data and
designations, refer to [EPA AQS](https://aqs.epa.gov/) and
[AirNow](https://www.airnow.gov/).
