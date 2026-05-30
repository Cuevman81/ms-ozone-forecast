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

```bash
# 1. Run the R pipeline (requires R with RAQSAPI, randomForest, terra, etc.)
Rscript Ozone_Master_Sync.R

# 2. Export JSON for the dashboard
Rscript web-dashboard/export_json.R

# 3. Push to deploy
cd web-dashboard && git add -A && git commit -m "Update data" && git push
```

## Project Structure

```
web-dashboard/
├── index.html          # Main dashboard (4 tabs)
├── css/style.css       # Dashboard styling
├── js/app.js           # Application logic (Plotly, Leaflet, DataTables)
├── dev_server.py       # Local dev server with sync/retrain API
├── export_json.R       # R script: CSV/RDS -> JSON conversion
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

This project is maintained by the Mississippi Department of Environmental Quality, Air Division.
