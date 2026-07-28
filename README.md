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
R Backend (scheduled)              Static Frontend (always on)
┌─────────────────────┐            ┌──────────────────────┐
│ Ozone_Data_Manager  │            │ index.html           │
│   EPA AQS + AirNow  │──export──>│ Plotly.js charts     │
│   Iowa ASOS weather │  (JSON)   │ Leaflet.js maps      │
│ Ozone_Model_Training│            │ DataTables           │
│   Random Forest     │            │ Deployed on Vercel   │
│ Ozone_Forecaster    │            └──────────────────────┘
│   NWS + NOAA AQM    │
└─────────────────────┘
```

The R pipeline fetches data, trains models, and generates forecasts. The `export_json.R` script converts the outputs to JSON files that the static web dashboard reads. No R server is needed at runtime.

## Automated Data Updates

The dashboard data is updated automatically via [GitHub Actions](https://github.com/Cuevman81/ms-ozone-forecast/actions) on two scheduled runs daily:

| Run | Time (Central) | Purpose |
|-----|---------------|---------|
| Morning | **6:00 AM CT** | Fetch overnight observed data, update models, generate initial forecast |
| Afternoon | **2:00 PM CT** | Capture completed 12z NOAA AQM model run, refresh forecast with latest data |

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
- **Trends & Analysis** — Variable importance plot, model control with status and retrain capability, historical time series comparing RF vs observed vs NOAA AQM models, scatter plot, error distribution, and performance metrics (RMSE, bias, MAE, R², POD, FAR) at overall, moderate, and USG thresholds.
- **Data Management** — Data completeness stats, sync status, and raw data preview.
- **About Station** — Site profile, coordinates, and satellite imagery map.

## Data Sources

- **Ozone observations:** [EPA AQS](https://aqs.epa.gov/aqsweb/documents/data_api.html) with [AirNow](https://www.airnow.gov/) fallback for recent days
- **Meteorology:** [Iowa State ASOS](https://mesonet.agron.iastate.edu/) daily summaries
- **Weather forecasts:** [NWS API](https://www.weather.gov/documentation/services-web-api) gridded forecast data
- **Air quality model:** [NOAA AQMv7](https://www.weather.gov/sti/stimodeling_airquality) (06z/12z cycles, regular and bias-corrected)
- **Real-time O3:** [AirNow S3](https://docs.airnowapi.org/) hourly data files

## Local Development

Run the dashboard locally with live data sync capability:

```bash
cd web-dashboard
python3 dev_server.py
# Open http://localhost:8080
```

The dev server provides:
- Static file serving for the dashboard
- **Sync & Refresh Ecosystem** button — triggers the full R pipeline (data sync, model training, forecasting, JSON export)
- **Retrain Model** button — retrains the RF model for the selected site
- **Real-time O3** proxy — fetches latest hourly ozone from AirNow

### Updating Data

Normally you do not need to: GitHub Actions runs the pipeline twice daily. To
run it by hand:

```bash
# Data sync + model training + forecasts + JSON export, in one step.
Rscript r-pipeline/run_pipeline.R

# Then push to deploy
git add -A && git commit -m "Update data" && git push
```

`run_pipeline.R` is the same entry point the scheduled workflow uses, so a manual
run and a scheduled run produce identical files.

### Running the Shiny app

```bash
# From the project root (the folder containing web-dashboard/)
Rscript -e 'shiny::runApp("web-dashboard/shiny-app")'
```

Or open `run_app.R` in RStudio and click Source.

## Single source of truth

Everything reads and writes **`r-pipeline/`** — the Shiny app, the JSON exporter,
the local dev server, and GitHub Actions. `app.R` resolves `DATA_DIR` to that
folder at startup and takes `sites_config.R` from it as well, so there is exactly
one copy of every CSV, model, and history log.

This matters: these files used to be duplicated in the project root, and the two
sets drifted two months apart. The app was forecasting from a stale model and
overwriting the pipeline's logged forecasts. The old copies are parked in
`../_legacy/` — see the README there.

The pipeline owns `history_<site>.csv`. The Shiny app displays it and never
writes to it.

## Project Structure

```
web-dashboard/                # <- git repo root
├── index.html          # Main dashboard (4 tabs)
├── css/style.css       # Dashboard styling
├── js/app.js           # Application logic (Plotly, Leaflet, DataTables)
├── dev_server.py       # Local dev server with sync/retrain API
├── export_json.R       # R script: CSV/RDS -> JSON conversion
├── vercel.json         # Cache-control and security headers
├── .vercelignore       # Keeps r-pipeline/ and shiny-app/ out of the deploy
├── shiny-app/
│   └── app.R           # The R Shiny app (run locally, not deployed)
├── r-pipeline/         # Source of truth: data, models, and pipeline scripts
│   ├── run_pipeline.R      # Entry point used by GitHub Actions
│   ├── sites_config.R      # Site metadata (the only copy)
│   ├── Ozone_Data_Manager.R / _Model_Training.R / _Forecaster.R
│   ├── aq_MetDaily_<site>.csv   # Training data
│   ├── model_<site>.rds         # Trained RF models
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
- **Frontend:** Vanilla HTML/CSS/JS
- **Charts:** [Plotly.js](https://plotly.com/javascript/)
- **Maps:** [Leaflet.js](https://leafletjs.com/)
- **Tables:** [DataTables](https://datatables.net/)
- **Hosting:** [Vercel](https://vercel.com/)

## License

This project is maintained by Rodney Cuevas RCuevas@mdeq.ms.gov.
