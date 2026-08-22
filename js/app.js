// MS Ozone Forecast — Static Web Dashboard
// Reads pre-exported JSON from data/ directory

const DATA_BASE = 'data';

let sitesConfig = [];
let currentSite = null;
let sidebarMap = null;
let aboutMapInstance = null;
// Today's history row, kept so the async real-time O3 value can be patched into
// the Today table without re-fetching or re-rendering the rest of the dashboard.
let currentTodayEntry = null;

// --- Initialization ---
document.addEventListener('DOMContentLoaded', async () => {
  setupNavigation();
  setupSubTabs();
  await detectLocalServer();
  await loadSitesConfig();
  await loadMeta();
});

// --- Navigation ---
function setupNavigation() {
  document.querySelectorAll('.sidebar-nav li').forEach(li => {
    li.addEventListener('click', () => {
      document.querySelectorAll('.sidebar-nav li').forEach(n => n.classList.remove('active'));
      li.classList.add('active');
      const tab = li.dataset.tab;
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
      document.getElementById('tab-' + tab).classList.add('active');

      if (tab === 'about' && currentSite) {
        setTimeout(() => renderAboutMap(), 100);
      }
      // Resize Plotly charts when their tab becomes visible (fixes initial hidden-render sizing)
      if (tab === 'analysis') {
        setTimeout(() => {
          document.querySelectorAll('#tab-analysis .js-plotly-plot').forEach(el => Plotly.Plots.resize(el));
        }, 150);
      }
      // Recalculate DataTable column widths when tab becomes visible
      setTimeout(() => $.fn.DataTable.tables({ visible: true, api: true }).columns.adjust(), 200);
    });
  });
}

function setupSubTabs() {
  document.querySelectorAll('.sub-tab').forEach(tab => {
    tab.addEventListener('click', () => {
      const parent = tab.closest('.card-body');
      parent.querySelectorAll('.sub-tab').forEach(t => t.classList.remove('active'));
      parent.querySelectorAll('.sub-panel').forEach(p => p.classList.remove('active'));
      tab.classList.add('active');
      const subPanel = document.getElementById('sub-' + tab.dataset.sub);
      subPanel.classList.add('active');
      // Resize Plotly charts when sub-tab becomes visible
      setTimeout(() => {
        subPanel.querySelectorAll('.js-plotly-plot').forEach(el => Plotly.Plots.resize(el));
      }, 150);
      setTimeout(() => $.fn.DataTable.tables({ visible: true, api: true }).columns.adjust(), 200);
    });
  });
}

// --- Load Sites Config ---
async function loadSitesConfig() {
  try {
    const res = await fetch(`${DATA_BASE}/sites_config.json`);
    sitesConfig = await res.json();
    populateRegionDropdown();
  } catch (e) {
    console.error('Failed to load sites config:', e);
    document.querySelector('.main-content').innerHTML =
      '<div class="loading"><i class="fas fa-exclamation-triangle"></i> Could not load site configuration. Run <code>export_json.R</code> first.</div>';
  }
}

async function loadMeta() {
  try {
    const res = await fetch(`${DATA_BASE}/meta.json`);
    const meta = await res.json();
    document.getElementById('exportDate').textContent = meta.exported_at || '--';
  } catch (e) {
    // meta is optional
  }
}

// --- Dropdowns ---
function populateRegionDropdown() {
  const regions = [...new Set(sitesConfig.map(s => s.region))];
  const sel = document.getElementById('regionSelect');
  sel.innerHTML = regions.map(r => `<option value="${r}">${r}</option>`).join('');
  sel.onchange = () => populateSiteDropdown();

  const siteSel = document.getElementById('siteSelect');
  siteSel.onchange = () => onSiteChange();

  populateSiteDropdown();
}

function populateSiteDropdown() {
  const region = document.getElementById('regionSelect').value;
  const sites = sitesConfig.filter(s => s.region === region);
  const sel = document.getElementById('siteSelect');
  sel.innerHTML = sites.map(s => `<option value="${s.name}">${s.name}</option>`).join('');
  onSiteChange();
}

async function onSiteChange() {
  const name = document.getElementById('siteSelect').value;
  currentSite = sitesConfig.find(s => s.name === name);
  if (!currentSite) return;

  document.getElementById('sidebarSiteName').textContent = name;
  renderSidebarMap();

  const safeName = name.replace(/ /g, '_');
  const basePath = `${DATA_BASE}/${safeName}`;

  // Start the real-time O3 lookup now but deliberately do NOT await it here.
  // It walks backwards through hourly AirNow files and routinely takes seconds
  // (longer, or never, when AirNow is slow). Awaiting it before rendering left
  // the entire dashboard blank on that call — for a value that fills exactly one
  // table cell. Render from local JSON first, then patch that cell in when it
  // lands. A rejected promise must not surface as an unhandled rejection.
  const realtimePromise = fetchJSON(
    isLocalServer
      ? `/api/realtime/${currentSite.aqs_id}`
      : `/api/realtime?aqs=${currentSite.aqs_id}`
  ).catch(() => null);

  // Load all data in parallel
  const [history, dataSummary, importance, metrics, recent] = await Promise.all([
    fetchJSON(`${basePath}/history.json`),
    fetchJSON(`${basePath}/data_summary.json`),
    fetchJSON(`${basePath}/importance.json`),
    fetchJSON(`${basePath}/metrics.json`),
    fetchJSON(`${basePath}/recent.json`),
  ]);

  renderSidebarStatus(dataSummary);
  renderDashboard(history, recent, dataSummary, null);
  renderAnalysis(history, importance, metrics, dataSummary);
  renderDataTab(dataSummary);
  renderAboutTab();

  // Resize all Plotly charts after layout settles (fixes narrow charts on initial page load)
  setTimeout(() => {
    document.querySelectorAll('.js-plotly-plot').forEach(el => Plotly.Plots.resize(el));
  }, 300);

  // Patch the real-time cell once it resolves, unless the user has since switched
  // sites — a slow response for the previous site must not overwrite the new one.
  realtimePromise.then(rt => {
    if (!rt || rt.value == null) return;
    if (!currentSite || currentSite.name !== name) return;
    renderTodayTable(currentTodayEntry, rt.value);
  });
}

async function fetchJSON(url) {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

// --- AQI Helpers ---
function getAqiInfo(ppm) {
  if (ppm == null || isNaN(ppm)) return { color: 'blue', status: 'Unknown', cssClass: 'vb-blue' };
  if (ppm <= 0.054) return { color: 'green', status: 'Good', cssClass: 'vb-green' };
  if (ppm <= 0.070) return { color: 'yellow', status: 'Moderate', cssClass: 'vb-yellow' };
  if (ppm <= 0.085) return { color: 'orange', status: 'Unhealthy for Sensitive Groups', cssClass: 'vb-orange' };
  if (ppm <= 0.105) return { color: 'red', status: 'Unhealthy', cssClass: 'vb-red' };
  if (ppm <= 0.200) return { color: 'purple', status: 'Very Unhealthy', cssClass: 'vb-purple' };
  return { color: 'maroon', status: 'Hazardous', cssClass: 'vb-maroon' };
}

function aqiCellClass(val) {
  if (val == null || isNaN(val)) return '';
  if (val <= 0.054) return 'aqi-good';
  if (val <= 0.070) return 'aqi-moderate';
  if (val <= 0.085) return 'aqi-usg';
  if (val <= 0.105) return 'aqi-unhealthy';
  if (val <= 0.200) return 'aqi-very-unhealthy';
  return 'aqi-hazardous';
}

// Inline style version for cells using style="" instead of class
function aqiCellStyle(val) {
  const cls = aqiCellClass(val);
  const map = {
    'aqi-good': 'background-color:#dff0d8;',
    'aqi-moderate': 'background-color:#fcf8e3;',
    'aqi-usg': 'background-color:#f2dede;',
    'aqi-unhealthy': 'background-color:#ebcccc;',
    'aqi-very-unhealthy': 'background-color:#f5e79e;',
    'aqi-hazardous': 'background-color:#e0b0ff;',
  };
  return map[cls] || '';
}

// Temp (F) color coding — matches app.R: c(32, 50, 70, 85)
function tempCellStyle(val) {
  if (val <= 32) return 'background-color:rgba(0,0,255,0.2);';
  if (val <= 50) return 'background-color:rgba(173,216,230,0.4);';
  if (val <= 70) return '';
  if (val <= 85) return 'background-color:rgba(255,165,0,0.4);';
  return 'background-color:rgba(255,0,0,0.4);';
}

// Dewpoint (F) color coding — matches app.R: c(30, 45, 60)
function dewpCellStyle(val) {
  if (val <= 30) return 'background-color:rgba(255,255,0,0.2);';
  if (val <= 45) return 'background-color:rgba(240,255,240,0.4);';
  if (val <= 60) return 'background-color:rgba(144,238,144,0.4);';
  return 'background-color:rgba(46,139,87,0.4);';
}

function fmt(val, digits = 4) {
  if (val == null || isNaN(val)) return 'N/A';
  return Number(val).toFixed(digits);
}

// --- Sidebar Map ---
function renderSidebarMap() {
  if (!currentSite) return;
  if (sidebarMap) sidebarMap.remove();
  sidebarMap = L.map('sidebarMap').setView([currentSite.lat, currentSite.lon], 10);
  L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png', {
    attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
    maxZoom: 19
  }).addTo(sidebarMap);
  L.marker([currentSite.lat, currentSite.lon])
    .bindPopup(`${currentSite.name}<br>AQS: ${currentSite.aqs_id}`)
    .addTo(sidebarMap);
}

function renderSidebarStatus(summary) {
  const el = document.getElementById('sidebarStatus');
  if (!summary) {
    el.innerHTML = '<span class="status-badge danger">No Data Found</span>';
    return;
  }
  if (summary.days_behind <= 1) {
    el.innerHTML = '<span class="status-badge success">Data Up to Date</span>';
  } else {
    el.innerHTML = '<span class="status-badge warning">Sync Recommended</span>';
  }
}

// --- Dashboard Tab ---
function renderDashboard(history, recent, summary, realtimeO3) {
  // Resolve the two entries once, on the local calendar, and share them.
  const todayEntry = history ? history.find(h => h.Target_Date === today()) : null;
  const tomorrowEntry = history ? history.find(h => h.Target_Date === tomorrow()) : null;
  currentTodayEntry = todayEntry;

  renderValueBoxes(history, tomorrowEntry);
  renderForecastTables(history, realtimeO3, todayEntry, tomorrowEntry);
  renderTrendPlot(recent);
}

function renderValueBoxes(history, tomorrowEntry) {
  const vbRF = document.getElementById('vbRF');
  const vbAQM = document.getElementById('vbAQM');
  const vbTemp = document.getElementById('vbTemp');

  if (!history || history.length === 0) {
    setValueBox(vbRF, 'N/A', "Tomorrow's RF Forecast", 'vb-blue');
    setValueBox(vbAQM, 'N/A', "Tomorrow's AQM Bias-Corr", 'vb-blue');
    setValueBox(vbTemp, 'N/A', "Tomorrow's Forecasted High", 'vb-orange');
    return;
  }

  // Prefer the entry actually targeting tomorrow. If the pipeline has not issued
  // it yet, fall back to the newest entry but say which date it is for, so a
  // stale forecast is never displayed as if it were tomorrow's.
  const latest = tomorrowEntry || history[0];
  const stale = !tomorrowEntry;
  const forLabel = stale ? ` (issued for ${latest.Target_Date})` : '';
  const prefix = stale ? 'Latest' : "Tomorrow's";

  const rfVal = latest.RF_Pred;
  const rfInfo = getAqiInfo(rfVal);
  setValueBox(vbRF,
    rfVal != null ? fmt(rfVal) + ' ppm' : 'N/A',
    `${prefix} RF Forecast: ${rfInfo.status}${forLabel}`,
    rfInfo.cssClass
  );

  const aqmVal = latest.AQM_12_BC;
  const aqmInfo = getAqiInfo(aqmVal);
  setValueBox(vbAQM,
    aqmVal != null ? fmt(aqmVal) + ' ppm' : 'N/A',
    `${prefix} AQM Bias-Corr: ${aqmInfo.status}${forLabel}`,
    aqmInfo.cssClass
  );

  const tempVal = latest.Met_Temp_F;
  setValueBox(vbTemp,
    tempVal != null ? tempVal.toFixed(1) + ' F' : 'N/A',
    `${prefix} Forecasted High Temp${forLabel}`,
    'vb-orange'
  );
}

function setValueBox(el, value, subtitle, cssClass) {
  const icon = el.querySelector('.vb-icon').innerHTML;
  el.className = 'value-box ' + cssClass;
  el.querySelector('.vb-content').innerHTML = `<h2>${value}</h2><p>${subtitle}</p>`;
}

function renderForecastTables(history, realtimeO3, todayEntry, tomorrowEntry) {
  if (!history || history.length === 0) {
    initEmptyTable('forecastTableToday');
    initEmptyTable('forecastTableTomorrow');
    return;
  }

  // Today's table: matches app.R forecast_today reactive
  renderTodayTable(todayEntry, realtimeO3);

  // Tomorrow's table: matches app.R forecast_res / forecast_table
  renderTomorrowTable(tomorrowEntry || history[0]);
}

function renderTodayTable(entry, realtimeO3) {
  const tableId = 'forecastTableToday';
  const table = document.getElementById(tableId);
  if ($.fn.DataTable.isDataTable('#' + tableId)) {
    $('#' + tableId).DataTable().destroy();
    table.innerHTML = '';
  }

  // Build rows matching app.R: Real-time O3, RF Prediction, AQM 12z Reg/BC, AQM 06z Reg/BC
  const rows = [
    ['Real-time O3 (Latest Hourly)', realtimeO3, today()],
    ['RF Prediction (Issued Previously)', entry ? entry.RF_Pred : null, entry ? entry.Run_Date : null],
    ['AQM 12z Reg', entry ? entry.AQM_12_Reg : null, entry ? entry.Run_Date : null],
    ['AQM 12z BC', entry ? entry.AQM_12_BC : null, entry ? entry.Run_Date : null],
    ['AQM 06z Reg', entry ? entry.AQM_06_Reg : null, entry ? entry.Run_Date : null],
    ['AQM 06z BC', entry ? entry.AQM_06_BC : null, entry ? entry.Run_Date : null],
  ];

  const thead = '<thead><tr><th>Source</th><th>Value (ppm)</th><th>Issued Date</th></tr></thead>';
  const tbody = '<tbody>' + rows.map(r =>
    `<tr><td>${r[0]}</td><td class="${aqiCellClass(r[1])}">${fmt(r[1])}</td><td>${r[2] || 'N/A'}</td></tr>`
  ).join('') + '</tbody>';

  table.innerHTML = thead + tbody;
  $('#' + tableId).DataTable({ paging: false, searching: false, info: false, ordering: false });
}

function renderTomorrowTable(entry) {
  const tableId = 'forecastTableTomorrow';
  const table = document.getElementById(tableId);
  if ($.fn.DataTable.isDataTable('#' + tableId)) {
    $('#' + tableId).DataTable().destroy();
    table.innerHTML = '';
  }

  if (!entry) {
    table.innerHTML = '<thead><tr><th>Source</th><th>Value (ppm)</th><th>Run Date</th><th>Sync Status</th></tr></thead><tbody><tr><td colspan="4">No data available</td></tr></tbody>';
    return;
  }

  // Build rows matching app.R: RF, AQM 06z Reg/BC, AQM 12z Reg/BC
  const rows = [
    ['Our Random Forest', entry.RF_Pred, 'Live Prediction', 'Calculated Now'],
    ['NOAA AQM 06z (Regular)', entry.AQM_06_Reg, entry.Run_Date, getSyncStatus(entry.Run_Date)],
    ['NOAA AQM 06z (Bias-Corr)', entry.AQM_06_BC, entry.Run_Date, getSyncStatus(entry.Run_Date)],
    ['NOAA AQM 12z (Regular)', entry.AQM_12_Reg, entry.Run_Date, getSyncStatus(entry.Run_Date)],
    ['NOAA AQM 12z (Bias-Corr)', entry.AQM_12_BC, entry.Run_Date, getSyncStatus(entry.Run_Date)],
  ];

  const thead = '<thead><tr><th>Source</th><th>Value (ppm)</th><th>Run Date</th><th>Sync Status</th></tr></thead>';
  const tbody = '<tbody>' + rows.map(r => {
    const statusColor = r[3] === 'Calculated Now' || r[3] === 'Current Run' ? '#2ecc71'
      : r[3] === 'Unavailable' ? '#e74c3c' : '#e67e22';
    return `<tr><td>${r[0]}</td><td class="${aqiCellClass(r[1])}">${fmt(r[1])}</td><td>${r[2] || 'N/A'}</td><td style="color:${statusColor}; font-weight:bold;">${r[3]}</td></tr>`;
  }).join('') + '</tbody>';

  table.innerHTML = thead + tbody;
  $('#' + tableId).DataTable({ paging: false, searching: false, info: false, ordering: false, autoWidth: true });
}

// Local-calendar date string (YYYY-MM-DD).
// Never use toISOString() for this: it returns UTC, so from ~7pm Central onward
// it reports tomorrow's date and every "today"/"tomorrow" lookup shifts by a day.
// app.R uses Sys.Date() (local), so this keeps the two in agreement.
function localDateStr(d = new Date()) {
  return d.getFullYear() + '-' +
    String(d.getMonth() + 1).padStart(2, '0') + '-' +
    String(d.getDate()).padStart(2, '0');
}

function today() {
  return localDateStr();
}

function tomorrow() {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return localDateStr(d);
}

function getSyncStatus(runDate) {
  if (!runDate || runDate === 'N/A') return 'Unavailable';
  if (runDate >= today()) return 'Current Run';
  return 'NWS Sync Delay (Falling back to previous run)';
}

function initEmptyTable(id) {
  const table = document.getElementById(id);
  if ($.fn.DataTable.isDataTable('#' + id)) {
    $('#' + id).DataTable().destroy();
  }
  table.innerHTML = '<thead><tr><th>Source</th><th>Value (ppm)</th></tr></thead><tbody><tr><td colspan="2">No data — run export_json.R</td></tr></tbody>';
}

// --- 7-Day Trend Plot ---
function renderTrendPlot(recent) {
  const el = document.getElementById('trendPlot');
  if (!recent || recent.length === 0) {
    Plotly.newPlot(el, [], { title: 'No recent data available', height: 320 });
    return;
  }

  const dates = recent.map(r => r.date);
  const o3 = recent.map(r => r.O3);

  const colors = o3.map(v => {
    if (v == null) return '#ccc';
    if (v <= 0.054) return '#00a65a';
    if (v <= 0.070) return '#f0ad4e';
    if (v <= 0.085) return '#ff851b';
    return '#dd4b39';
  });

  const trace = {
    x: dates,
    y: o3,
    type: 'scatter',
    mode: 'lines+markers',
    line: { color: 'steelblue', width: 2 },
    marker: { color: colors, size: 10 },
    name: 'O3'
  };

  const layout = {
    title: `Recent Ozone Levels for ${currentSite.name}`,
    xaxis: { title: 'Date' },
    yaxis: { title: 'Max 8-hr Ozone (ppm)' },
    height: 320,
    margin: { t: 40, b: 50, l: 60, r: 20 },
    showlegend: false,
    shapes: [{
      type: 'line', x0: dates[0], x1: dates[dates.length - 1],
      y0: 0.070, y1: 0.070,
      line: { color: 'rgba(255,0,0,0.5)', width: 1.5, dash: 'dash' }
    }],
    annotations: [{
      x: dates[dates.length - 1], y: 0.070, text: 'NAAQS',
      showarrow: false, yshift: 10, font: { size: 10, color: 'red' }
    }]
  };

  Plotly.newPlot(el, [trace], layout, { responsive: true });
}

// --- Analysis Tab ---
function renderAnalysis(history, importance, metrics, dataSummary) {
  renderImportancePlot(importance);
  renderModelStatus(dataSummary, metrics);
  renderPerformancePlots(history);
  renderMetricsTables(metrics);
  renderHistoryTable(history);
}

function renderModelStatus(dataSummary, metrics) {
  const labelEl = document.getElementById('modelStatusLabel');
  const metricsEl = document.getElementById('modelMetricsText');

  if (!dataSummary) {
    labelEl.innerHTML = '<span class="status-badge danger" style="font-size:1.1em;">Action: Train Required</span>';
    metricsEl.textContent = '';
    return;
  }

  // Show retrain button only when running local dev server
  const retrainBtn = document.getElementById('retrainBtn');
  if (isLocalServer) retrainBtn.style.display = 'flex';

  if (dataSummary.days_behind <= 1) {
    labelEl.innerHTML = '<span class="status-badge success" style="font-size:1.1em;">Status: Model Optimized</span>';
  } else {
    labelEl.innerHTML = '<span class="status-badge warning" style="font-size:1.1em;">Action: Retrain Recommended (New Data)</span>';
  }

  if (metrics && metrics.overall && metrics.overall.RF) {
    const rf = metrics.overall.RF;
    metricsEl.innerHTML = `<strong>RF Model:</strong> RMSE = ${fmt(rf.rmse)}, R² = ${rf.r2 != null ? rf.r2.toFixed(3) : 'N/A'}, N = ${rf.n}`;
  }
}

function renderImportancePlot(importance) {
  const el = document.getElementById('importancePlot');
  if (!importance || importance.length === 0) {
    Plotly.newPlot(el, [], { title: 'No model data', height: 320 });
    return;
  }

  const sorted = [...importance].sort((a, b) => a['%IncMSE'] - b['%IncMSE']);

  const trace = {
    y: sorted.map(d => d.Feature),
    x: sorted.map(d => d['%IncMSE']),
    type: 'bar',
    orientation: 'h',
    marker: { color: 'steelblue' },
    hovertemplate: '%{y}: %{x:.1f}<extra></extra>'
  };

  // One row per feature. At a fixed 320px the 18 features only got ~13px each,
  // so Plotly thinned the tick labels to every other category and the names no
  // longer sat beside their own bars. Grow the plot with the feature count and
  // pin dtick to 1 so every bar keeps its label.
  const rowPx = 22;
  const chromePx = 90; // title + x-axis title + margins
  const height = Math.max(320, sorted.length * rowPx + chromePx);

  Plotly.newPlot(el, [trace], {
    title: 'Variable Importance (%IncMSE)',
    height: height,
    margin: { l: 10, r: 20, t: 40, b: 50 },
    xaxis: { title: '% Increase in MSE' },
    yaxis: {
      type: 'category',
      tickmode: 'linear',
      dtick: 1,
      automargin: true,
      ticks: 'outside',
      ticklen: 4,
      tickfont: { size: 11 }
    }
  }, { responsive: true });
}

function renderPerformancePlots(history) {
  if (!history || history.length === 0) return;

  // For seasonal sites: pad all dates in range and null out off-season (Nov 1 – Feb 14)
  let df = history;
  if (currentSite.seasonal && df.length > 1) {
    const allDates = df.map(r => r.Target_Date).sort();
    const startDate = new Date(allDates[0] + 'T00:00:00');
    const endDate = new Date(allDates[allDates.length - 1] + 'T00:00:00');
    const dateMap = {};
    df.forEach(r => { dateMap[r.Target_Date] = r; });

    const padded = [];
    for (let d = new Date(startDate); d <= endDate; d.setDate(d.getDate() + 1)) {
      const key = localDateStr(d);
      const m = d.getMonth() + 1;
      const day = d.getDate();
      const offSeason = m >= 11 || m === 1 || (m === 2 && day < 15);

      if (offSeason) {
        padded.push({ Target_Date: key, Observed_O3: null, RF_Pred: null, AQM_06_Reg: null, AQM_06_BC: null, AQM_12_Reg: null, AQM_12_BC: null });
      } else if (dateMap[key]) {
        padded.push(dateMap[key]);
      } else {
        padded.push({ Target_Date: key, Observed_O3: null, RF_Pred: null, AQM_06_Reg: null, AQM_06_BC: null, AQM_12_Reg: null, AQM_12_BC: null });
      }
    }
    df = padded;
  }

  // Time series
  const dates = df.map(r => r.Target_Date);
  const traces = [
    { x: dates, y: df.map(r => r.Observed_O3), name: 'Observed', line: { color: 'black', width: 2 } },
    { x: dates, y: df.map(r => r.RF_Pred), name: 'RF Prediction', line: { color: '#3c8dbc', dash: 'dash' } },
  ];

  if (df.some(r => r.AQM_06_Reg != null))
    traces.push({ x: dates, y: df.map(r => r.AQM_06_Reg), name: 'AQM 06z Reg', line: { color: '#e74c3c', width: 1, dash: 'dot' } });
  if (df.some(r => r.AQM_06_BC != null))
    traces.push({ x: dates, y: df.map(r => r.AQM_06_BC), name: 'AQM 06z BC', line: { color: '#c0392b', width: 1.5, dash: 'dot' } });
  if (df.some(r => r.AQM_12_Reg != null))
    traces.push({ x: dates, y: df.map(r => r.AQM_12_Reg), name: 'AQM 12z Reg', line: { color: '#f1c40f', width: 1, dash: 'dot' } });
  if (df.some(r => r.AQM_12_BC != null))
    traces.push({ x: dates, y: df.map(r => r.AQM_12_BC), name: 'AQM 12z BC', line: { color: '#f39c12', width: 1.5, dash: 'dot' } });

  traces.forEach(t => { t.type = 'scatter'; t.mode = 'lines'; t.connectgaps = false; });

  Plotly.newPlot('perfTimeSeries', traces, {
    title: 'Historical Comparison',
    yaxis: { title: 'Ozone (ppm)' },
    hovermode: 'x unified',
    legend: { orientation: 'h', y: -0.25 },
    height: 400,
    margin: { t: 40, b: 80, l: 60, r: 20 },
    shapes: [{
      type: 'line', x0: dates[0], x1: dates[dates.length - 1],
      y0: 0.070, y1: 0.070,
      line: { color: 'rgba(255,0,0,0.5)', width: 1.5, dash: 'dash' }
    }],
    annotations: [{
      x: dates[dates.length - 1], y: 0.070, text: 'NAAQS (0.070 ppm)',
      showarrow: false, yshift: 10, font: { size: 10, color: 'red' }
    }]
  }, { responsive: true });

  // Scatter: RF vs Observed
  const paired = df.filter(r => r.RF_Pred != null && r.Observed_O3 != null);
  if (paired.length > 1) {
    const maxVal = Math.max(...paired.map(r => Math.max(r.RF_Pred, r.Observed_O3)));
    Plotly.newPlot('perfScatter', [
      {
        x: paired.map(r => r.Observed_O3),
        y: paired.map(r => r.RF_Pred),
        type: 'scatter', mode: 'markers',
        marker: { opacity: 0.5, size: 8, color: '#3c8dbc' },
        name: 'RF vs Observed'
      },
      {
        x: [0, maxVal], y: [0, maxVal],
        type: 'scatter', mode: 'lines',
        line: { color: 'gray', dash: 'dash' },
        showlegend: false, name: '1:1'
      }
    ], {
      title: 'RF Prediction vs Observed',
      xaxis: { title: 'Observed O3 (ppm)' },
      yaxis: { title: 'RF Predicted O3 (ppm)' },
      height: 350, showlegend: false,
      margin: { t: 40, b: 50, l: 60, r: 20 }
    }, { responsive: true });

    // Error distribution
    const errors = paired.map(r => r.RF_Pred - r.Observed_O3);
    Plotly.newPlot('perfErrorDist', [{
      x: errors, type: 'histogram',
      marker: { color: '#3c8dbc', opacity: 0.7 },
      name: 'RF Error'
    }], {
      title: 'Model Error Distribution (Bias)',
      xaxis: { title: 'Prediction Error (ppm)' },
      yaxis: { title: 'Frequency' },
      bargap: 0.1, height: 350,
      margin: { t: 40, b: 50, l: 60, r: 20 }
    }, { responsive: true });
  }
}

// Kept so the provenance selector can re-render without re-fetching.
let currentMetrics = null;

function renderMetricsTables(metrics) {
  currentMetrics = metrics;
  const sel = document.getElementById('perfTypeFilter');
  if (sel && !sel.dataset.bound) {
    sel.addEventListener('change', () => renderMetricsTables(currentMetrics));
    sel.dataset.bound = '1';
  }

  if (!metrics) {
    document.getElementById('metricsOverall').innerHTML = '<p>No metrics available.</p>';
    document.getElementById('metricsModerate').innerHTML = '';
    document.getElementById('metricsUSG').innerHTML = '';
    return;
  }

  // by_type is written by export_json.R. Fall back to the pooled blocks so an
  // older data/ export still renders instead of blanking the panel.
  const key = sel ? sel.value : 'all';
  const block = (metrics.by_type && metrics.by_type[key]) || null;
  const src = block || metrics;

  const note = document.getElementById('perfTypeNote');
  if (note) {
    if (!block) {
      note.textContent = '';
    } else if (key === 'all') {
      note.style.color = '#b9770e';
      note.innerHTML = '<strong>Pooled.</strong> Mixes real forecasts with perfect-prognosis hindcasts, so the RF column flatters itself against the AQM columns.';
    } else if (!block.n_scorable) {
      note.style.color = '#c0392b';
      note.textContent = `No scorable rows yet (${block.n_rows} row(s), none with an observation). Operational rows can only be scored once the observed value arrives.`;
    } else {
      note.style.color = '#777';
      note.textContent = `${block.n_rows} row(s), ${block.n_scorable} scorable.` +
        (block.n_scorable < 30 ? ' Small sample — read with care.' : '');
    }
  }

  document.getElementById('metricsOverall').innerHTML = buildMetricsTable(src.overall, false);
  document.getElementById('metricsModerate').innerHTML = buildMetricsTable(src.moderate, true);
  document.getElementById('metricsUSG').innerHTML = buildMetricsTable(src.usg, true);
}

function buildMetricsTable(data, showCategorical) {
  if (!data) return '<p>Insufficient data.</p>';

  const models = ['RF', 'AQM_06R', 'AQM_06BC', 'AQM_12R', 'AQM_12BC'];
  const labels = ['RF', '06z Reg', '06z BC', '12z Reg', '12z BC'];

  let rows = [
    ['N', m => m.n],
    ['RMSE (ppm)', m => fmt(m.rmse)],
    ['Mean Bias', m => fmt(m.bias)],
    ['MAE', m => fmt(m.mae)],
    ['NMB (%)', m => m.nmb != null ? m.nmb.toFixed(1) : 'N/A'],
    ['NME (%)', m => m.nme != null ? m.nme.toFixed(1) : 'N/A'],
    ['R²', m => m.r2 != null ? m.r2.toFixed(3) : 'N/A'],
  ];

  if (showCategorical) {
    rows.push(['Hits / Miss / FA', m =>
      m.hits != null ? `${m.hits} / ${m.misses} / ${m.fas}` : 'N/A']);
    rows.push(['POD (Hit Rate)', m => m.pod != null ? m.pod.toFixed(2) : 'N/A']);
    rows.push(['FAR', m => m.far != null ? m.far.toFixed(2) : 'N/A']);
    rows.push(['CSI (Threat Score)', m => m.csi != null ? m.csi.toFixed(2) : 'N/A']);
  }

  let html = '<table class="metrics-table"><thead><tr><th>Metric</th>';
  labels.forEach(l => { html += `<th>${l}</th>`; });
  html += '</tr></thead><tbody>';

  rows.forEach(([label, getter]) => {
    html += `<tr><td>${label}</td>`;
    models.forEach(m => {
      const val = data[m] ? getter(data[m]) : 'N/A';
      html += `<td>${val}</td>`;
    });
    html += '</tr>';
  });

  html += '</tbody></table>';
  return html;
}

// --- History Table ---
function renderHistoryTable(history) {
  const tableId = 'historyTable';
  if ($.fn.DataTable.isDataTable('#' + tableId)) {
    $('#' + tableId).DataTable().destroy();
    document.getElementById(tableId).innerHTML = '';
  }

  if (!history || history.length === 0) {
    document.getElementById(tableId).innerHTML = '<p>No history data.</p>';
    return;
  }

  const cols = [
    'Run_Date', 'Target_Date', 'Observed_O3', 'RF_Pred',
    'AQM_06_Reg', 'AQM_06_BC', 'AQM_12_Reg', 'AQM_12_BC',
    'Met_Temp_F', 'Met_Dewp_F', 'Met_WS_kts', 'Met_WD_deg', 'Forecast_Type'
  ];
  const headers = [
    'Run Date', 'Target Date', 'Observed O3', 'RF Prediction',
    'AQM 06z Reg', 'AQM 06z BC', 'AQM 12z Reg', 'AQM 12z BC',
    'Max Temp (F)', 'Min Dewp (F)', 'Avg Wind (kts)', 'Wind Dir (°)', 'Type'
  ];
  const o3Cols = new Set(['Observed_O3', 'RF_Pred', 'AQM_06_Reg', 'AQM_06_BC', 'AQM_12_Reg', 'AQM_12_BC']);

  // Filter seasonal if needed
  let filtered = history;
  if (currentSite.seasonal) {
    filtered = history.filter(row => {
      const d = new Date(row.Target_Date);
      const m = d.getMonth() + 1;
      const day = d.getDate();
      return (m > 2 && m <= 10) || (m === 2 && day >= 15);
    });
  }

  // Build DataTables using columns API for proper alignment
  const tableData = filtered.map(row => cols.map(col => row[col] != null ? row[col] : null));

  document.getElementById(tableId).innerHTML = '';

  $('#' + tableId).DataTable({
    data: tableData,
    columns: headers.map((h, i) => ({ title: h })),
    pageLength: 25,
    autoWidth: true,
    order: [[0, 'desc']],
    columnDefs: [
      {
        targets: [2, 3, 4, 5, 6, 7],
        render: function(data) { return data != null ? Number(data).toFixed(4) : 'N/A'; },
        createdCell: function(td, data) {
          if (data != null) td.style.cssText = aqiCellStyle(data);
        }
      },
      {
        targets: [8],
        render: function(data) { return data != null ? data : 'N/A'; },
        createdCell: function(td, data) {
          if (data != null) td.style.cssText = tempCellStyle(data);
        }
      },
      {
        targets: [9],
        render: function(data) { return data != null ? data : 'N/A'; },
        createdCell: function(td, data) {
          if (data != null) td.style.cssText = dewpCellStyle(data);
        }
      },
      {
        targets: [10, 11],
        render: function(data) { return data != null ? data : 'N/A'; }
      },
      {
        // Provenance of RF_Pred. Hindcast rows used observed target-day weather,
        // so they are not comparable to real forecasts — mark them clearly.
        targets: [12],
        render: function(data) {
          if (data == null) return '<span style="color:#aaa;">legacy</span>';
          return data === 'operational'
            ? '<span style="color:#00a65a; font-weight:600;">operational</span>'
            : '<span style="color:#f39c12; font-weight:600;">hindcast</span>';
        }
      }
    ]
  });
}

// --- Data Management Tab ---
function renderDataTab(summary) {
  const row1 = document.getElementById('dataInfoBoxesRow1');
  const row2 = document.getElementById('dataInfoBoxesRow2');

  if (!summary) {
    row1.innerHTML = '<div class="info-box red"><div class="ib-icon"><i class="fas fa-times-circle"></i></div><div class="ib-content"><h4>Status</h4><p>No Data</p></div></div>';
    row2.innerHTML = '';
    initEmptyTable('dataPreviewTable');
    return;
  }

  const syncStatus = summary.days_behind <= 1
    ? { label: 'Up to Date', icon: 'check-circle', color: 'green' }
    : { label: `${summary.days_behind} Days Behind`, icon: 'exclamation-triangle', color: 'yellow' };

  const years = summary.years_span || 0;

  // Row 1: Total Records, Latest Observation, Sync Status (matches app.R)
  row1.innerHTML = `
    <div class="info-box light-blue">
      <div class="ib-icon"><i class="fas fa-database"></i></div>
      <div class="ib-content"><h4>Total Records</h4><p>${(summary.total_records || 0).toLocaleString()}</p></div>
    </div>
    <div class="info-box purple">
      <div class="ib-icon"><i class="fas fa-calendar-check"></i></div>
      <div class="ib-content"><h4>Latest Observation</h4><p>${summary.latest_date || 'N/A'}</p></div>
    </div>
    <div class="info-box ${syncStatus.color}">
      <div class="ib-icon"><i class="fas fa-${syncStatus.icon}"></i></div>
      <div class="ib-content"><h4>Sync Status</h4><p>${syncStatus.label}</p></div>
    </div>
  `;

  // Row 2: Training Hub Since, Model Experience, Data Completeness (matches app.R)
  row2.innerHTML = `
    <div class="info-box navy">
      <div class="ib-icon"><i class="fas fa-history"></i></div>
      <div class="ib-content"><h4>Training Hub Since</h4><p>${summary.earliest_date || 'N/A'}</p></div>
    </div>
    <div class="info-box yellow">
      <div class="ib-icon"><i class="fas fa-award"></i></div>
      <div class="ib-content"><h4>Model Experience</h4><p>${years} Years</p></div>
    </div>
    <div class="info-box orange">
      <div class="ib-icon"><i class="fas fa-chart-pie"></i></div>
      <div class="ib-content"><h4>Data Completeness</h4><p>${summary.completeness_pct || 0}%</p></div>
    </div>
  `;

  renderDataPreview(summary.last_5_rows);
}

function renderDataPreview(rows) {
  const tableId = 'dataPreviewTable';
  if ($.fn.DataTable.isDataTable('#' + tableId)) {
    $('#' + tableId).DataTable().destroy();
    document.getElementById(tableId).innerHTML = '';
  }

  if (!rows || rows.length === 0) {
    document.getElementById(tableId).innerHTML = '<p>No data preview available.</p>';
    return;
  }

  const keys = ['date', 'O3', 'max_temp_f', 'min_dewpoint_f', 'ws', 'wd'];
  const labels = ['Date', 'O3 (ppm)', 'Max Temp (F)', 'Min Dewp (F)', 'Avg Wind (kts)', 'Wind Dir (°)'];

  let thead = '<thead><tr>' + labels.map(h => `<th>${h}</th>`).join('') + '</tr></thead>';
  let tbody = '<tbody>';

  rows.forEach(row => {
    tbody += '<tr>';
    keys.forEach((k, i) => {
      const val = row[k];
      if (i >= 1 && val != null) {
        tbody += `<td>${Number(val).toFixed(3)}</td>`;
      } else {
        tbody += `<td>${val != null ? val : 'N/A'}</td>`;
      }
    });
    tbody += '</tr>';
  });

  tbody += '</tbody>';
  document.getElementById(tableId).innerHTML = thead + tbody;
  $('#' + tableId).DataTable({ paging: false, searching: false, info: false, autoWidth: true });
}

// --- About Tab ---
function renderAboutTab() {
  if (!currentSite) return;

  const table = document.getElementById('aboutSiteTable');
  table.innerHTML = `
    <tr><td><strong>Station Name:</strong></td><td>${currentSite.name}</td></tr>
    <tr><td><strong>Network Region:</strong></td><td>${currentSite.region}</td></tr>
    <tr><td><strong>System AQS ID:</strong></td><td>${currentSite.aqs_id}</td></tr>
    <tr><td><strong>Monitor Schedule:</strong></td><td>${currentSite.seasonal ? 'Seasonal (Mar-Oct)' : 'Year-Round'}</td></tr>
    <tr><td><strong>Latitude:</strong></td><td>${currentSite.lat}</td></tr>
    <tr><td><strong>Longitude:</strong></td><td>${currentSite.lon}</td></tr>
    <tr><td><strong>Met Data Source:</strong></td><td>ASOS Station ${currentSite.asos}</td></tr>
  `;

  renderAboutMap();
}

function renderAboutMap() {
  if (!currentSite) return;
  if (aboutMapInstance) aboutMapInstance.remove();

  aboutMapInstance = L.map('aboutMap').setView([currentSite.lat, currentSite.lon], 15);
  L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
    attribution: 'Esri World Imagery',
    maxZoom: 18
  }).addTo(aboutMapInstance);
  L.tileLayer('https://{s}.basemaps.cartocdn.com/light_only_labels/{z}/{x}/{y}{r}.png', {
    maxZoom: 18
  }).addTo(aboutMapInstance);
  L.marker([currentSite.lat, currentSite.lon])
    .bindPopup(`<b>${currentSite.name}</b><br>AQS: ${currentSite.aqs_id}`)
    .addTo(aboutMapInstance);
}

// --- Local Sync (dev server only) ---
let isLocalServer = false;

async function detectLocalServer() {
  try {
    const res = await fetch('/api/sync/status');
    if (res.ok) {
      isLocalServer = true;
      document.getElementById('syncControls').style.display = 'block';
    }
  } catch {
    // Not running dev_server.py — hide sync button (already hidden by default)
  }
}

async function triggerSync() {
  const btn = document.getElementById('syncBtn');
  const statusEl = document.getElementById('syncStatus');

  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Running Pipeline...';
  statusEl.textContent = 'Starting sync — this may take a few minutes...';

  try {
    const res = await fetch('/api/sync', { method: 'POST' });
    const data = await res.json();

    if (data.status === 'already_running') {
      statusEl.textContent = 'Sync already in progress...';
    }

    pollSyncStatus();
  } catch (e) {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-globe"></i> Sync & Refresh Ecosystem';
    statusEl.textContent = 'Error: Could not reach local server.';
  }
}

async function pollSyncStatus() {
  const btn = document.getElementById('syncBtn');
  const statusEl = document.getElementById('syncStatus');

  const poll = async () => {
    try {
      const res = await fetch('/api/sync/status');
      const data = await res.json();

      if (data.running) {
        const lines = (data.log || '').trim().split('\n');
        const lastLine = lines[lines.length - 1] || 'Working...';
        statusEl.textContent = lastLine;
        setTimeout(poll, 2000);
      } else {
        btn.disabled = false;
        btn.innerHTML = '<i class="fas fa-globe"></i> Sync & Refresh Ecosystem';
        statusEl.innerHTML = '<span style="color:#00a65a;">Sync complete! Reloading data...</span>';

        // Reload the current site data
        await onSiteChange();
        statusEl.innerHTML = '<span style="color:#00a65a;">Done — dashboard refreshed.</span>';
        setTimeout(() => { statusEl.textContent = ''; }, 5000);
      }
    } catch {
      btn.disabled = false;
      btn.innerHTML = '<i class="fas fa-globe"></i> Sync & Refresh Ecosystem';
      statusEl.textContent = 'Lost connection to server.';
    }
  };

  setTimeout(poll, 2000);
}

async function triggerRetrain() {
  if (!currentSite) return;
  const btn = document.getElementById('retrainBtn');
  const statusEl = document.getElementById('retrainStatus');

  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Retraining...';
  statusEl.textContent = `Retraining model for ${currentSite.name}...`;

  try {
    const res = await fetch(`/api/retrain/${encodeURIComponent(currentSite.name)}`, { method: 'POST' });
    const data = await res.json();

    if (data.status === 'complete') {
      statusEl.innerHTML = '<span style="color:#00a65a;">Model retrained! Reloading...</span>';
      await onSiteChange();
      statusEl.innerHTML = '<span style="color:#00a65a;">Done.</span>';
      setTimeout(() => { statusEl.textContent = ''; }, 5000);
    } else {
      statusEl.textContent = `Error: ${data.message || 'Retrain failed'}`;
    }
  } catch (e) {
    statusEl.textContent = 'Error: Could not reach server.';
  }

  btn.disabled = false;
  btn.innerHTML = '<i class="fas fa-brain"></i> Retrain Model';
}
