(function () {
  const READINGS_URL = 'api/readings.php';
  const DAILY_URL = 'api/daily.php';
  const FORECAST_URL = 'api/forecast.php';
  const GEOCODE_URL = 'api/geocode.php';
  const SETTINGS_URL = 'api/settings.php';
  const SYNC_TRIGGER_URL = 'api/sync_trigger.php';
  const DEPLOY_TRIGGER_URL = 'api/deploy_trigger.php';
  const REFRESH_MS = 60000; // poll for new data every minute
  const FORECAST_REFRESH_MS = REFRESH_MS * 5; // forecast.php itself caches Open-Meteo for 30min
  const RANGE_STORAGE_KEY = 'hiveRange';
  const FORECAST_RANGE_STORAGE_KEY = 'hiveForecastRange';
  // The fixed chip set for logged-out visitors (and brand-new profiles) —
  // matches api/settings.php's DEFAULT_RANGES. A logged-in profile can
  // replace this list entirely via the Settings tab's editor; see
  // availableRanges below and renderChips().
  const DEFAULT_RANGES = ['12h', '24h', '2d', '5d', '1m', 'all'];
  const MAX_CHART_POINTS = 1500; // per-sensor downsample cap for the two timeline charts
  // Hairline gridlines/night bands are drawn in the current theme's text
  // color (dark ink on the light theme, light ink on the dark theme), read
  // fresh on every draw rather than cached so a theme toggle repaints them
  // correctly — see applyTheme()'s redraw call.
  const gridColor = () => cssVar('--color-text');

  const ns = 'http://www.w3.org/2000/svg';
  const el = (id) => document.getElementById(id);
  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const makeEl = (tag, attrs) => {
    const e = document.createElementNS(ns, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  };

  // Dataviz skill's validated 8-hue categorical order — fixed, never
  // reassigned when a sensor is hidden via the legend. Sensors are colored
  // in the order the API returns them (sorted by name), stably.
  const SERIES_COLORS = [
    '#2a78d6', '#eb6834', '#1baf7a', '#eda100',
    '#e87ba4', '#008300', '#4a3aa7', '#e34948',
  ];

  let currentRange = localStorage.getItem(RANGE_STORAGE_KEY) || '24h';
  let sensors = [];        // [{id, name, description, online, last_ping_at, dht22_fault, dht22_fault_since, latest, stats, status, battery_voltage_v, battery_current_ma, battery_power_w, uptime_seconds, commit_hash, commit_summary, commit_date}]
  let series = {};         // { sensorId: [{recorded_at, temperature_c, humidity_pct, sample_count, attempt_count, max_attempts}] }
  let dailySeries = {};    // { sensorId: [{day, temp_avg, temp_min, temp_max}] }
  let hidden = new Set();  // sensor ids toggled off via the legend
  let statusLabel = 'Loading…';
  let nextFetchAt = Date.now() + REFRESH_MS;
  let chartGeom = {};      // svgId -> x/y mapping of its last render, for the linked crosshair

  let forecastRange = localStorage.getItem(FORECAST_RANGE_STORAGE_KEY) || '24h';
  // One api/forecast.php payload (or null on a failed fetch) per forecast
  // target, keyed by forecastTargets()'s `key` — 'default' for the
  // hardcoded Brno location, or a place's id (as a string) otherwise. See
  // loadForecast()/renderForecastCards().
  let forecastData = {};
  let forecastLoaded = false; // loaded lazily, the first time the Forecast tab is opened

  // This profile's saved forecast locations (Settings tab's Forecast
  // section) — settings.php's `places`, see its docstring and
  // ../../../../db/database/sensors/tables/forecast_places.md. Empty for a
  // logged-out visitor, same convention as sensorLabels: no profile means
  // no saved places, and the Forecast tab plots api/forecast.php's own
  // hardcoded default location (Brno) instead — see forecastTargets().
  let forecastPlaces = []; // [{id, name, latitude, longitude}]

  // What the Forecast tab actually renders: one card per saved place, or a
  // single "Brno" default when none are saved. `key` is stable and unique
  // per target — used to line up forecastData entries and to detect
  // whether ensureForecastCards() needs to rebuild the card list at all.
  function forecastTargets() {
    if (forecastPlaces.length) {
      return forecastPlaces.map((p) => ({ key: String(p.id), name: p.name, latitude: p.latitude, longitude: p.longitude }));
    }
    return [{ key: 'default', name: 'Brno', latitude: null, longitude: null }];
  }

  // -- Settings (password-profile-backed range persistence) -------------------
  // See api/settings.php's docstring: no username, a password just picks a
  // profile. Logged out, range chips behave exactly as before (the fixed
  // DEFAULT_RANGES set, localStorage only). Logged in, chip clicks also save
  // to that profile, and the Settings tab lets you edit availableRanges
  // itself (add/remove/reorder), so the choice — and the chip set it's
  // chosen from — follows you to other browsers/devices.
  let settingsLoggedIn = false;
  let availableRanges = DEFAULT_RANGES.slice(); // shared by both Overview and Forecast chip rows
  // This profile's own sensor-name -> friendly-label map (settings.php's
  // `sensor_labels`, see its docstring) — private per profile, so it's only
  // ever populated while logged in and cleared back to {} on logout. Empty
  // (not fetched at all) for a logged-out visitor, who sees device names
  // only, same as the ranges editor being unavailable to them.
  let sensorLabels = {};

  // -- Theme (light/dark) ------------------------------------------------------
  // The actual data-theme attribute is set as early as possible by the
  // inline <script> in index.html's <head>, to avoid a flash of the wrong
  // theme on load. currentTheme here just mirrors that for the toggle's own
  // state; this module owns switching it from then on.
  const THEME_STORAGE_KEY = 'hiveTheme';
  let currentTheme = document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';

  function applyTheme(theme) {
    currentTheme = theme;
    document.documentElement.setAttribute('data-theme', theme);
    const toggle = el('theme-toggle');
    if (toggle) toggle.setAttribute('aria-checked', theme === 'dark' ? 'true' : 'false');
  }

  // Gridlines and the chart end-marker ring are drawn with plain SVG
  // attributes (not CSS), so they don't repaint on their own when the
  // theme's CSS variables change — redraw whatever's currently on screen.
  function redrawThemedCharts() {
    if (sensors.length) {
      drawChart('chart-temp', 'temperature_c', '°C', 220);
      drawChart('chart-hum', 'humidity_pct', '%', 220);
      drawLongChart();
    }
    if (forecastLoaded) renderForecastCards();
  }

  el('theme-toggle').addEventListener('click', () => {
    const next = currentTheme === 'dark' ? 'light' : 'dark';
    localStorage.setItem(THEME_STORAGE_KEY, next);
    applyTheme(next);
    redrawThemedCharts();
  });
  applyTheme(currentTheme); // sync the toggle's aria-checked to match the head script's choice

  function fmtTime(iso) {
    const d = new Date(iso);
    return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  }
  function fmtRelative(iso) {
    const diffMs = Date.now() - new Date(iso).getTime();
    const mins = Math.round(diffMs / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + 'm ago';
    const hours = Math.round(mins / 60);
    if (hours < 24) return hours + 'h ago';
    return Math.round(hours / 24) + 'd ago';
  }

  // success/failed/max — see readings.md's attempt_count/max_attempts in
  // the `db` project. Rows written before that tracking existed have
  // neither, so fall back to the plain successful-sample count they
  // always had.
  function formatSamples(point) {
    if (point.attempt_count == null || point.max_attempts == null) return String(point.sample_count);
    return `${point.sample_count}/${point.attempt_count - point.sample_count}/${point.max_attempts}`;
  }

  // A sensor's label — this profile's own entry in sensorLabels, set from
  // the Settings tab (api/settings.php's save_sensor_label) — stands in for
  // its device `name` wherever the dashboard shows sensor identity. Returns
  // null (rather than falling back itself) so callers can also decide
  // whether to show the device-name watermark/title only when a label is
  // actually standing in for it.
  function labelFor(s) {
    const l = sensorLabels[s.name];
    return (l && l.trim()) ? l : null;
  }
  function displayName(s) {
    return labelFor(s) || s.name;
  }

  function colorFor(sensorId) {
    const idx = sensors.findIndex((s) => s.id === sensorId);
    if (idx < 0) return SERIES_COLORS[0];
    return SERIES_COLORS[idx % SERIES_COLORS.length];
  }

  // Binary search for the index in `times` (ascending) closest to `t`.
  function nearestIndex(times, t) {
    let lo = 0, hi = times.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (times[mid] < t) lo = mid + 1; else hi = mid;
    }
    if (lo > 0 && Math.abs(times[lo - 1] - t) <= Math.abs(times[lo] - t)) return lo - 1;
    return lo;
  }

  function downsample(points, max) {
    if (points.length <= max) return points;
    const stride = Math.ceil(points.length / max);
    const out = [];
    for (let i = 0; i < points.length; i += stride) out.push(points[i]);
    const last = points[points.length - 1];
    if (out[out.length - 1] !== last) out.push(last);
    return out;
  }

  // -- Fetch ------------------------------------------------------------------
  // api/*.php always answers with JSON, even on failure (db.php's fail()
  // emits {"error": "..."}), so surface that message instead of a bare
  // status code — it's the difference between "HTTP 500" and knowing why.
  async function fetchJson(url) {
    const res = await fetch(url, { cache: 'no-store' });
    if (!res.ok) {
      let detail = 'HTTP ' + res.status;
      try {
        const body = await res.json();
        if (body && body.error) detail = body.error;
      } catch { /* body wasn't JSON — stick with the status code */ }
      throw new Error(detail);
    }
    return res.json();
  }

  // POST helper shared by api/settings.php and api/sync_trigger.php — both
  // expect a JSON body and the X-Requested-With header as a cheap CSRF speed
  // bump (see settings.php's docstring). Throws with the server's own
  // {"error": "..."} message on failure, same convention as fetchJson.
  async function postJson(url, body) {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'fetch' },
      body: JSON.stringify(body),
    });
    let payload = null;
    try { payload = await res.json(); } catch { /* fall through to status-based error below */ }
    if (!res.ok) throw new Error((payload && payload.error) || 'HTTP ' + res.status);
    return payload;
  }

  function postSettings(action, body) {
    return postJson(SETTINGS_URL, { action, ...body });
  }

  async function loadReadings() {
    nextFetchAt = Date.now() + REFRESH_MS;
    try {
      const payload = await fetchJson(`${READINGS_URL}?range=${encodeURIComponent(currentRange)}`);
      sensors = payload.sensors || [];
      series = payload.series || {};
      hidden = new Set([...hidden].filter((id) => sensors.some((s) => s.id === id)));
      statusLabel = sensors.some((s) => s.online) ? 'Live' : 'No sensor online';
      renderAll(payload);
      renderSyncList(); // keep the Settings tab's online/offline badges and IPs current even while it's not the visible tab
      // A returning, already-logged-in browser calls showSettingsLoggedIn()
      // (and so renderLabelList()) before this first load ever resolves, so
      // that first render sees an empty `sensors` array and produces an
      // empty list. Fill it in once real data shows up — but only while
      // still empty, so this never wipes out someone's in-progress edit on
      // a later 60s poll.
      if (settingsLoggedIn && el('label-list').children.length === 0) renderLabelList();
    } catch (err) {
      statusLabel = 'Unable to reach the Hive';
      renderStatus();
      console.error('Failed to load readings:', err.message);
    }
  }

  async function loadDaily() {
    try {
      const payload = await fetchJson(DAILY_URL);
      dailySeries = payload.series || {};
      drawLongChart();
    } catch (err) {
      console.error('Failed to load 12-month history:', err.message);
    }
  }

  // Builds one empty .chart-card for a forecast target — same markup as the
  // Overview tab's chart cards (corners, chart-head, chart-wrap>svg). No
  // per-card footer — the hour-count/"Queried" line that used to live there
  // just ate vertical space the chart itself should have, so it's gone.
  // Built via createElement/textContent throughout (never innerHTML with
  // interpolated text) since a place's `name` came from api/geocode.php,
  // i.e. text this dashboard didn't author.
  function buildForecastCard(target) {
    const section = document.createElement('section');
    section.className = 'chart-card';
    for (const pos of ['tl', 'tr', 'bl', 'br']) {
      const corner = document.createElement('i');
      corner.className = 'corner ' + pos;
      section.appendChild(corner);
    }

    const head = document.createElement('div');
    head.className = 'chart-head';
    const title = document.createElement('span');
    title.className = 'chart-title';
    title.textContent = `Temperature forecast — ${target.name} (Open-Meteo)`;
    const note = document.createElement('span');
    note.className = 'chart-note';
    head.append(title, note);

    const wrap = document.createElement('div');
    wrap.className = 'chart-wrap';
    const svg = makeEl('svg', { viewBox: '0 0 1000 240', preserveAspectRatio: 'none' });
    wrap.appendChild(svg);

    section.append(head, wrap);
    return section;
  }

  // Rebuilds #forecast-cards' children to match `targets`, but only when
  // the actual set/order of targets changed (tracked via a joined-keys
  // marker) — a plain data refresh (the 5-minute poll, a range-chip click)
  // reuses the existing cards/SVGs instead of tearing them down, so nothing
  // flickers or loses scroll position for an unrelated update.
  function ensureForecastCards(targets) {
    const container = el('forecast-cards');
    const wantKeys = targets.map((t) => t.key).join('|');
    if (container.dataset.keys === wantKeys) return;
    container.innerHTML = '';
    targets.forEach((t) => container.appendChild(buildForecastCard(t)));
    container.dataset.keys = wantKeys;
  }

  // Draws every card from forecastTargets()/forecastData's current state —
  // called both after a fetch (loadForecast()) and on a theme toggle
  // (redrawThemedCharts()), which only needs to recolor already-fetched
  // data, not refetch it. Relies on ensureForecastCards() having already
  // put the cards in the same order as forecastTargets() returns.
  function renderForecastCards() {
    const targets = forecastTargets();
    const cards = [...el('forecast-cards').children];
    targets.forEach((t, i) => {
      const card = cards[i];
      if (!card) return; // ensureForecastCards() hasn't run yet for this target set
      const payload = forecastData[t.key];
      drawForecastChart(card.querySelector('svg'), (payload && payload.readings) || []);
      card.querySelector('.chart-note').textContent = !payload
        ? "couldn't reach Open-Meteo and there's no cached forecast either"
        : payload.clamped
          ? `shaded bands = approx. night (20:00–06:00) · bars = hourly rain/snow · Open-Meteo only forecasts ${payload.forecast_days_max} days ahead — showing the max available`
          : 'shaded bands = approx. night (20:00–06:00) · bars = hourly rain/snow';
    });
  }

  // Fetches every current target's forecast in parallel (one api/forecast.php
  // call per place, each cached server-side under its own coordinates — see
  // that file's docstring) and draws them all. A target that fails to load
  // gets forecastData[key] = null rather than dropping its card, so it still
  // renders — just with the "couldn't reach Open-Meteo" message in place of
  // a chart, same as the single-location design used to show.
  async function loadForecast() {
    const targets = forecastTargets();
    ensureForecastCards(targets);
    renderForecastCards(); // paint whatever's already cached before the fetches below land, so a card never flashes blank
    await Promise.all(targets.map(async (t) => {
      try {
        let url = `${FORECAST_URL}?range=${encodeURIComponent(forecastRange)}`;
        if (t.latitude !== null) {
          url += `&lat=${encodeURIComponent(t.latitude)}&lon=${encodeURIComponent(t.longitude)}`;
        }
        forecastData[t.key] = await fetchJson(url);
      } catch (err) {
        console.error(`Failed to load forecast for ${t.name}:`, err.message);
        forecastData[t.key] = null;
      }
    }));
    renderForecastCards();
  }

  function renderStatus() {
    const secsLeft = Math.max(0, Math.round((nextFetchAt - Date.now()) / 1000));
    el('status').textContent = `${statusLabel} · next refresh in ${secsLeft}s`;
  }

  // -- Top-level render ---------------------------------------------------------
  function renderAll(payload) {
    const hasAnyReading = sensors.some((s) => s.latest);
    el('empty-state').hidden = hasAnyReading;
    el('tile-grid').style.display = hasAnyReading ? 'grid' : 'none';
    ['section-temp', 'section-hum', 'section-long'].forEach((id) => {
      el(id).style.display = hasAnyReading ? 'block' : 'none';
    });
    document.querySelector('.table-wrap').style.display = hasAnyReading ? 'block' : 'none';

    renderStatus();
    if (!hasAnyReading) return;

    renderLegend();
    renderTiles();
    drawChart('chart-temp', 'temperature_c', '°C', 220);
    drawChart('chart-hum', 'humidity_pct', '%', 220);
    drawLongChart();
    drawTable();
    updateFavicon();

    el('footer-count').textContent = payload.count + ' reading' + (payload.count === 1 ? '' : 's') + ' in window';
    el('footer-generated').textContent = 'Queried ' + fmtTime(payload.generated_at);
  }

  // -- Favicon — recolors itself at the extremes, same thresholds as the
  //    per-Zero dashboard, but driven off the average of all sensors' latest
  //    readings (and their average trend) since the Hive has more than one). --
  const TREND_SAMPLE_COUNT = 5;
  const TREND_FLAT_THRESHOLD_C = 0.2;
  const FAVICON_HOT_THRESHOLD_C = 25;
  const FAVICON_COLD_THRESHOLD_C = 20;
  const FAVICON_HOT_COLOR = '#e54848';
  const FAVICON_COLD_COLOR = '#4c8df6';
  const faviconTintCache = new Map();

  function avgLatestTemp() {
    const temps = sensors.filter((s) => s.latest).map((s) => s.latest.temperature_c);
    if (!temps.length) return null;
    return temps.reduce((a, b) => a + b, 0) / temps.length;
  }

  // Compares a single sensor's last few readings to gauge whether its
  // temperature is trending up, down, or flat. Drives both the per-tile
  // delta badge and (averaged across sensors) the favicon.
  function getSensorTempTrend(sensorId) {
    const pts = series[sensorId];
    if (!pts) return null;
    const n = Math.min(TREND_SAMPLE_COUNT, pts.length);
    if (n < 2) return null;
    const recent = pts.slice(-n);
    const diff = recent[recent.length - 1].temperature_c - recent[0].temperature_c;
    let direction = 'flat';
    if (diff > TREND_FLAT_THRESHOLD_C) direction = 'up';
    else if (diff < -TREND_FLAT_THRESHOLD_C) direction = 'down';
    return { direction, diff };
  }

  // Averages each sensor's own recent trend rather than diffing the average
  // series, so a sensor that drops out mid-window doesn't skew the read.
  function getAvgTempTrend() {
    const trends = sensors.map((s) => getSensorTempTrend(s.id)).filter(Boolean);
    if (!trends.length) return null;
    const diff = trends.reduce((a, t) => a + t.diff, 0) / trends.length;
    let direction = 'flat';
    if (diff > TREND_FLAT_THRESHOLD_C) direction = 'up';
    else if (diff < -TREND_FLAT_THRESHOLD_C) direction = 'down';
    return { direction, diff };
  }

  function tempIconColor(tempC) {
    if (typeof tempC !== 'number') return null;
    if (tempC > FAVICON_HOT_THRESHOLD_C) return FAVICON_HOT_COLOR;
    if (tempC < FAVICON_COLD_THRESHOLD_C) return FAVICON_COLD_COLOR;
    return null; // within the normal range - keep the icon's original color
  }

  // Recolors a favicon PNG via canvas ('source-in' keeps the icon's alpha
  // shape, replacing only its visible pixels with the given color) since
  // PNGs can't be recolored with CSS the way an inline SVG could.
  function setFaviconTinted(src, color) {
    const cacheKey = src + '|' + color;
    const cached = faviconTintCache.get(cacheKey);
    if (cached) {
      el('favicon').setAttribute('href', cached);
      return;
    }
    if (!color) {
      el('favicon').setAttribute('href', src);
      return;
    }
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0);
      ctx.globalCompositeOperation = 'source-in';
      ctx.fillStyle = color;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      const dataUrl = canvas.toDataURL('image/png');
      faviconTintCache.set(cacheKey, dataUrl);
      el('favicon').setAttribute('href', dataUrl);
    };
    img.src = src;
  }

  function updateFavicon() {
    const trend = getAvgTempTrend();
    const icons = { up: 'thermometer-up-48.png', down: 'thermometer-down-48.png', flat: 'thermometer-48.png' };
    const direction = trend ? trend.direction : 'flat';
    setFaviconTinted('icon/' + icons[direction], tempIconColor(avgLatestTemp()));
  }

  // -- Legend — click to toggle a sensor's series in both charts ---------------
  function renderLegend() {
    const box = el('legend');
    box.innerHTML = '';
    sensors.forEach((s) => {
      const item = document.createElement('button');
      item.className = 'legend-item' + (hidden.has(s.id) ? ' dim' : '');
      item.type = 'button';
      const swatch = document.createElement('span');
      swatch.className = 'legend-swatch';
      swatch.style.background = colorFor(s.id);
      const label = document.createElement('span');
      label.textContent = displayName(s); // from the DB — textContent, never innerHTML
      if (labelFor(s)) item.title = s.name; // device name, on hover, when a label is standing in for it
      item.append(swatch, label);
      item.addEventListener('click', () => {
        if (hidden.has(s.id)) hidden.delete(s.id); else hidden.add(s.id);
        renderLegend();
        drawChart('chart-temp', 'temperature_c', '°C', 220);
        drawChart('chart-hum', 'humidity_pct', '%', 220);
        drawLongChart();
      });
      box.appendChild(item);
    });
  }

  // -- Sensor tiles ---------------------------------------------------------------
  function renderTiles() {
    const grid = el('tile-grid');
    grid.innerHTML = '';
    sensors.forEach((s) => {
      const tile = document.createElement('div');
      tile.className = 'tile' + (s.online ? '' : ' offline');

      const head = document.createElement('div');
      head.className = 'tile-head';
      const label = document.createElement('span');
      label.className = 'tile-label';
      label.textContent = displayName(s);
      // Independent badges, all shown at once — a sensor can be ONLINE,
      // BATTERY <pct>% and FAULTY DHT22 simultaneously (a Pi with a loose
      // DHT22 still answers pings, and a UPS's charge state has nothing to
      // do with either). See readings.php: `online` (ping-based),
      // `status` (ups_ina219.py) and `dht22_fault` (dht22_logger.py).
      const badges = document.createElement('span');
      badges.className = 'tile-badges';

      const connBadge = document.createElement('span');
      connBadge.className = 'tile-badge';
      connBadge.textContent = s.online ? 'ONLINE' : 'OFFLINE';
      if (s.last_ping_at) connBadge.title = 'Last ping ' + fmtRelative(s.last_ping_at);
      badges.appendChild(connBadge);

      if (s.status && s.status !== 'OK') {
        // "CHARGING <pct>%" / "BATTERY <pct>%" from ups_ina219.py, via
        // sensors.status — see readings.php. Anything else (no UPS HAT
        // fitted, or status not yet reported) is omitted entirely.
        const powerBadge = document.createElement('span');
        powerBadge.className = 'tile-badge ' + (s.status.startsWith('CHARGING') ? 'charging' : 'battery');
        powerBadge.textContent = s.status;
        badges.appendChild(powerBadge);
      }

      if (s.dht22_fault) {
        const faultBadge = document.createElement('span');
        faultBadge.className = 'tile-badge fault';
        faultBadge.textContent = 'FAULTY DHT22';
        if (s.dht22_fault_since) faultBadge.title = 'Failing to read since ' + fmtRelative(s.dht22_fault_since);
        badges.appendChild(faultBadge);
      }

      head.append(label, badges);
      tile.appendChild(head);

      // Device name, watermarked into the background — only when a label is
      // actually standing in for it above; otherwise tile-label already
      // shows the device name and a second copy would be redundant.
      if (labelFor(s)) {
        const nameBg = document.createElement('span');
        nameBg.className = 'tile-name-bg';
        nameBg.textContent = s.name;
        tile.appendChild(nameBg);
      }

      const value = document.createElement('div');
      value.className = 'tile-value';
      if (s.latest) {
        const num = document.createElement('span');
        num.textContent = s.latest.temperature_c.toFixed(1);
        const unit = document.createElement('span');
        unit.className = 'unit';
        unit.textContent = '°C';
        value.append(num, unit);
        const trend = getSensorTempTrend(s.id);
        if (trend) {
          const arrows = { up: '▲', down: '▼', flat: '▬' };
          const trendBadge = document.createElement('span');
          trendBadge.className = 'trend-badge trend-' + trend.direction;
          trendBadge.textContent = `${arrows[trend.direction]} ${Math.abs(trend.diff).toFixed(1)}°`;
          value.appendChild(trendBadge);
        }
      } else {
        value.textContent = '—';
      }
      tile.appendChild(value);

      const hum = document.createElement('div');
      hum.className = 'tile-humidity';
      hum.textContent = s.latest ? s.latest.humidity_pct.toFixed(0) + ' % RH' : 'no data';
      tile.appendChild(hum);

      const spark = makeEl('svg', { viewBox: '0 0 120 26', preserveAspectRatio: 'none', class: 'tile-spark' });
      const pts = (series[s.id] || []).slice(-30);
      if (pts.length >= 2) {
        const temps = pts.map((p) => p.temperature_c);
        const tMin = Math.min(...temps), tMax = Math.max(...temps);
        const span = tMax - tMin || 1;
        const step = 120 / (pts.length - 1);
        const points = pts.map((p, i) => `${(i * step).toFixed(1)},${(24 - ((p.temperature_c - tMin) / span) * 22).toFixed(1)}`).join(' ');
        spark.appendChild(makeEl('polyline', { fill: 'none', stroke: colorFor(s.id), 'stroke-width': 1.4, points }));
      }
      tile.appendChild(spark);

      const meta = document.createElement('div');
      meta.className = 'tile-stats';
      meta.textContent = s.stats
        ? `min ${s.stats.temp_min} · avg ${s.stats.temp_avg} · max ${s.stats.temp_max}`
        : 'no readings in window';
      tile.appendChild(meta);

      if (!s.online) {
        const lastSeen = document.createElement('div');
        lastSeen.className = 'tile-meta';
        lastSeen.textContent = s.latest ? 'last seen ' + fmtRelative(s.latest.recorded_at) : 'never reported';
        tile.appendChild(lastSeen);
      }

      ['tl', 'tr', 'bl', 'br'].forEach((c) => tile.appendChild(makeEl('i', { class: 'corner ' + c })));
      grid.appendChild(tile);
    });
  }

  // -- Recent readings table — the accessibility fallback: every value the
  //    charts and tiles show is also reachable here, with no hover needed ----
  function drawTable() {
    const rows = [];
    for (const s of sensors) {
      for (const p of (series[s.id] || [])) rows.push({ sensor: s, point: p });
    }
    rows.sort((a, b) => new Date(b.point.recorded_at) - new Date(a.point.recorded_at));
    const body = el('log-body');
    body.innerHTML = '';
    for (const { sensor, point } of rows.slice(0, 40)) {
      const tr = document.createElement('tr');
      const tdTime = document.createElement('td');
      tdTime.textContent = fmtTime(point.recorded_at);
      const tdSensor = document.createElement('td');
      tdSensor.className = 'swatch-cell';
      const sw = document.createElement('span');
      sw.className = 'legend-swatch';
      sw.style.background = colorFor(sensor.id);
      const nameSpan = document.createElement('span');
      nameSpan.textContent = displayName(sensor);
      if (labelFor(sensor)) nameSpan.title = sensor.name;
      tdSensor.append(sw, nameSpan);
      const tdTemp = document.createElement('td');
      tdTemp.textContent = point.temperature_c.toFixed(1);
      const tdHum = document.createElement('td');
      tdHum.textContent = point.humidity_pct.toFixed(1);
      const tdSamples = document.createElement('td');
      tdSamples.textContent = formatSamples(point);
      tr.append(tdTime, tdSensor, tdTemp, tdHum, tdSamples);
      body.appendChild(tr);
    }
  }

  // Fixed 20:00-06:00 local-time approximation for night shading — unlike the
  // per-Zero dashboard this has no sunrise/sunset API dependency, since a
  // household dashboard doesn't need to the minute.
  function nightBands(tMin, tMax) {
    const bands = [];
    const day = new Date(tMin);
    day.setHours(0, 0, 0, 0);
    for (; day.getTime() <= tMax; day.setDate(day.getDate() + 1)) {
      const morningEnd = new Date(day); morningEnd.setHours(6, 0, 0, 0);
      const eveningStart = new Date(day); eveningStart.setHours(20, 0, 0, 0);
      const nextMidnight = new Date(day); nextMidnight.setDate(nextMidnight.getDate() + 1);
      bands.push([day.getTime(), morningEnd.getTime()]);
      bands.push([eveningStart.getTime(), nextMidnight.getTime()]);
    }
    return bands.map(([a, b]) => [Math.max(a, tMin), Math.min(b, tMax)]).filter(([a, b]) => b > a);
  }

  const HOUR_STEPS = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168, 336, 720, 1440];

  function hourTickStep(rangeHours, plotW) {
    for (const step of HOUR_STEPS) {
      // Midnight ticks always render as a full date label ("Sep 7"), not an
      // hour, regardless of step (see the label logic where stepHours is
      // used) - so once the visible range can span more than a day, every
      // tick needs to clear that wider width, or the date label merges into
      // its hour-labeled neighbors. A 2-day range is the first place this
      // bites: it's dense enough to otherwise pick an hourly step.
      const labelWidthPx = (step >= 24 || rangeHours > 24) ? 54 : 14;
      const maxTicks = Math.max(2, Math.floor(plotW / labelWidthPx));
      if (rangeHours / step <= maxTicks) return step;
    }
    return HOUR_STEPS[HOUR_STEPS.length - 1];
  }

  // Same idea as hourTickStep, but for spacing fixed-size items (icons)
  // rather than text labels whose width varies with the tick format.
  function stepHoursForPx(rangeHours, plotW, minPxPerItem) {
    for (const step of HOUR_STEPS) {
      const maxTicks = Math.max(1, Math.floor(plotW / minPxPerItem));
      if (rangeHours / step <= maxTicks) return step;
    }
    return HOUR_STEPS[HOUR_STEPS.length - 1];
  }

  const MONTH_STEPS = [1, 2, 3, 4, 6, 12, 24, 36, 60];

  // Time axis ticks shared by the Overview and Forecast charts (drawChart(),
  // drawForecastChart()) - returns [{time, label, major}], where `major`
  // marks a day (or month) boundary tick for the bolder gridline treatment.
  //
  // Below a ~60-day range this steps by hourTickStep()'s hours, same as
  // before, but anchored to local midnight rather than to the first whole
  // hour at/after tMin. That anchor matters: every HOUR_STEPS value is
  // either a divisor or a multiple of 24, so a midnight-anchored lattice is
  // guaranteed to land exactly on midnight at the expected cadence, however
  // tMin happens to be offset from it. Anchoring to an arbitrary hour offset
  // instead (the old behavior) meant midnight - and with it, the only tick
  // that ever printed a date - could fall between lattice points for the
  // *entire* visible range, e.g. a forecast fetched at 14:00 stepping every
  // 8h lands on 14, 22, 06, 14, 22, 06, ... and never once on 00. That's
  // exactly what a 5-day range showing hour-only labels looks like: days
  // are more informative than hours once the range spans more than one, so
  // every day in range must get a labeled tick, not just whichever hours
  // the step lattice happens to land on.
  //
  // Above ~60 days - HOUR_STEPS' own ceiling, and the point where a further
  // day-multiple step would drift away from calendar month boundaries the
  // longer the range gets - ticks switch to whole months anchored to the
  // 1st, same convention as the long-term chart's own month ticks
  // (drawLongChart()): months are more informative than days at that scale,
  // so each visible month gets its own label instead of a handful of
  // arbitrary ~30-day-spaced dates.
  function timeAxisTicks(tMin, tMax, plotW) {
    const rangeHours = (tMax - tMin) / 3600000;
    const rangeDays = rangeHours / 24;
    const ticks = [];

    if (rangeDays > 60) {
      const labelWidthPx = 34; // "Sep" - matches drawLongChart()'s own month label
      const maxTicks = Math.max(2, Math.floor(plotW / labelWidthPx));
      const rangeMonths = rangeDays / 30;
      let stepMonths = MONTH_STEPS[MONTH_STEPS.length - 1];
      for (const step of MONTH_STEPS) {
        if (rangeMonths / step <= maxTicks) { stepMonths = step; break; }
      }
      const m = new Date(tMin);
      m.setDate(1);
      m.setHours(0, 0, 0, 0);
      if (m.getTime() < tMin) m.setMonth(m.getMonth() + 1);
      for (; m.getTime() <= tMax; m.setMonth(m.getMonth() + stepMonths)) {
        ticks.push({ time: m.getTime(), major: true, label: m.toLocaleString(undefined, { month: 'short' }) });
      }
      return ticks;
    }

    const stepHours = hourTickStep(rangeHours, plotW);
    const dayStart = new Date(tMin);
    dayStart.setHours(0, 0, 0, 0);
    const tick = new Date(dayStart);
    while (tick.getTime() < tMin) tick.setHours(tick.getHours() + stepHours);
    for (; tick.getTime() <= tMax; tick.setHours(tick.getHours() + stepHours)) {
      const isMidnight = tick.getHours() === 0;
      const label = (stepHours >= 24 || isMidnight) ? tick.toLocaleString(undefined, { month: 'short', day: 'numeric' }) : String(tick.getHours()).padStart(2, '0');
      ticks.push({ time: tick.getTime(), major: isMidnight, label });
    }
    return ticks;
  }

  // -- Temperature / humidity charts — one axis each (no dual-axis), shared
  //    time domain, linked crosshair. ------------------------------------------
  function drawChart(svgId, valueKey, unit, H) {
    const svg = el(svgId);
    svg.innerHTML = '';
    const W = 1000, marginLeft = 46, marginRight = 20, marginTop = 14, marginBottom = 28;
    const plotW = W - marginLeft - marginRight;
    const plotH = H - marginTop - marginBottom;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

    const visible = sensors.filter((s) => !hidden.has(s.id) && (series[s.id] || []).length);
    if (!visible.length) {
      svg.appendChild(makeEl('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle', 'font-size': 13 })).textContent = 'No data in this window';
      delete chartGeom[svgId];
      return;
    }

    let tMin = Infinity, tMax = -Infinity, vMin = Infinity, vMax = -Infinity;
    const perSensor = visible.map((s) => {
      const pts = series[s.id];
      tMin = Math.min(tMin, new Date(pts[0].recorded_at).getTime());
      tMax = Math.max(tMax, new Date(pts[pts.length - 1].recorded_at).getTime());
      for (const p of pts) {
        const v = p[valueKey];
        if (v < vMin) vMin = v;
        if (v > vMax) vMax = v;
      }
      return { sensor: s, points: downsample(pts, MAX_CHART_POINTS) };
    });
    if (tMax === tMin) tMax = tMin + 3600000;

    const isTemp = valueKey === 'temperature_c';
    if (isTemp) {
      const vPad = 1;
      vMin = Math.floor(vMin - vPad);
      vMax = Math.ceil(vMax + vPad);
      if (vMax === vMin) vMax = vMin + 1;
    } else {
      // Humidity is always plotted over its full physical range, not
      // autoscaled to the data — 50% shouldn't look identical to a
      // wobble between 48-52%.
      vMin = 0;
      vMax = 100;
    }

    const x = (t) => marginLeft + ((t - tMin) / (tMax - tMin || 1)) * plotW;
    const y = (v) => marginTop + plotH - ((v - vMin) / (vMax - vMin || 1)) * plotH;
    chartGeom[svgId] = { tMin, tMax, marginLeft, marginRight, marginTop, marginBottom, W, H, plotW, plotH };

    for (const [a, b] of nightBands(tMin, tMax)) {
      svg.appendChild(makeEl('rect', { x: x(a), y: marginTop, width: Math.max(0, x(b) - x(a)), height: plotH, fill: gridColor(), 'fill-opacity': 0.05 }));
    }

    const vStepRaw = (vMax - vMin) / 4;
    const vStep = isTemp ? Math.max(1, Math.round(vStepRaw)) : Math.max(5, Math.round(vStepRaw / 5) * 5);
    for (let v = Math.ceil(vMin / vStep) * vStep; v <= vMax; v += vStep) {
      svg.appendChild(makeEl('line', { x1: marginLeft, x2: W - marginRight, y1: y(v), y2: y(v), stroke: gridColor(), 'stroke-opacity': 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: marginLeft - 8, y: y(v) + 4, 'text-anchor': 'end', 'font-size': 10 })).textContent = isTemp ? v.toFixed(0) + '°' : v.toFixed(0) + unit;
    }

    for (const t of timeAxisTicks(tMin, tMax, plotW)) {
      const xPos = x(t.time);
      svg.appendChild(makeEl('line', { x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom, stroke: gridColor(), 'stroke-opacity': t.major ? 0.3 : 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': 10 })).textContent = t.label;
    }

    for (const { sensor, points } of perSensor) {
      const color = colorFor(sensor.id);
      const d = points.map((p, i) => (i === 0 ? 'M' : 'L') + x(new Date(p.recorded_at).getTime()).toFixed(1) + ',' + y(p[valueKey]).toFixed(1)).join(' ');
      svg.appendChild(makeEl('path', { d, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', opacity: sensor.online ? 1 : 0.55 }));
      const last = points[points.length - 1];
      const cx = x(new Date(last.recorded_at).getTime()), cy = y(last[valueKey]);
      // 2px surface ring so the end-marker stays legible where lines cross
      // — matches the card background, so it must be read live (not the
      // '#f2f2f3' light-theme literal) to stay correct in dark mode.
      svg.appendChild(makeEl('circle', { cx, cy, r: 5.5, fill: cssVar('--color-bg') }));
      svg.appendChild(makeEl('circle', { cx, cy, r: 4, fill: color }));
    }
  }

  // -- Long-term chart: daily mean per sensor over the last 12 months ---------
  function drawLongChart() {
    const svg = el('chart-long');
    if (!svg) return;
    svg.innerHTML = '';
    const W = 1000, H = 200, marginLeft = 46, marginRight = 20, marginTop = 14, marginBottom = 28;
    const plotW = W - marginLeft - marginRight, plotH = H - marginTop - marginBottom;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

    const visible = sensors.filter((s) => !hidden.has(s.id) && (dailySeries[s.id] || []).length);
    if (!visible.length) {
      svg.appendChild(makeEl('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle', 'font-size': 13 })).textContent = 'Not enough long-term data yet';
      return;
    }

    let tMin = Infinity, tMax = -Infinity, vMin = Infinity, vMax = -Infinity;
    for (const s of visible) {
      for (const p of dailySeries[s.id]) {
        const t = new Date(p.day + 'T00:00:00').getTime();
        if (t < tMin) tMin = t;
        if (t > tMax) tMax = t;
        if (p.temp_avg < vMin) vMin = p.temp_avg;
        if (p.temp_avg > vMax) vMax = p.temp_avg;
      }
    }
    if (tMax === tMin) tMax = tMin + 86400000;
    vMin = Math.floor(vMin - 1);
    vMax = Math.ceil(vMax + 1);
    if (vMax === vMin) vMax = vMin + 1;

    const x = (t) => marginLeft + ((t - tMin) / (tMax - tMin || 1)) * plotW;
    const y = (v) => marginTop + plotH - ((v - vMin) / (vMax - vMin || 1)) * plotH;

    const vStep = Math.max(1, Math.round((vMax - vMin) / 4));
    for (let v = Math.ceil(vMin / vStep) * vStep; v <= vMax; v += vStep) {
      svg.appendChild(makeEl('line', { x1: marginLeft, x2: W - marginRight, y1: y(v), y2: y(v), stroke: gridColor(), 'stroke-opacity': 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: marginLeft - 8, y: y(v) + 4, 'text-anchor': 'end', 'font-size': 10 })).textContent = v.toFixed(0) + '°';
    }

    const monthTick = new Date(tMin);
    monthTick.setDate(1);
    monthTick.setHours(0, 0, 0, 0);
    if (monthTick.getTime() < tMin) monthTick.setMonth(monthTick.getMonth() + 1);
    for (; monthTick.getTime() <= tMax; monthTick.setMonth(monthTick.getMonth() + 1)) {
      const xPos = x(monthTick.getTime());
      svg.appendChild(makeEl('line', { x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom, stroke: gridColor(), 'stroke-opacity': 0.15, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': 10 })).textContent = monthTick.toLocaleString(undefined, { month: 'short' });
    }

    for (const s of visible) {
      const color = colorFor(s.id);
      const pts = dailySeries[s.id];
      const d = pts.map((p, i) => (i === 0 ? 'M' : 'L') + x(new Date(p.day + 'T00:00:00').getTime()).toFixed(1) + ',' + y(p.temp_avg).toFixed(1)).join(' ');
      svg.appendChild(makeEl('path', { d, fill: 'none', stroke: color, 'stroke-width': 1.75, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
    }
  }

  // -- Forecast tab — Open-Meteo hourly forecast for Brno (temperature,
  //    humidity, wind, condition icons). Ported from rpi-zero's
  //    drawWeatherChart(): same combo-chart shape (one dual-axis line chart
  //    plus an icon strip), the only real difference being that this plots
  //    api/forecast.php's forward-looking rows instead of a historical
  //    comparison. Night bands reuse the same fixed 20:00-06:00
  //    approximation as the Overview charts (see nightBands() above) rather
  //    than rpi-zero's real sunrise/sunset markers, since the Hive has no
  //    sun_times data to draw from. -------------------------------------------
  function pickWeatherIcon(weatherCode, night) {
    if (typeof weatherCode !== 'number') return 'cloud-48.png';
    if (weatherCode === 0) return night ? 'night-48.png' : 'sun-48.png';
    if (weatherCode === 1 || weatherCode === 2) return 'partly-cloudy-day-48.png';
    if (weatherCode === 3 || weatherCode === 45 || weatherCode === 48) return 'clouds-48.png';
    if (weatherCode >= 51) return 'cloud-lightning-48.png';
    return 'cloud-48.png';
  }

  function isNightApprox(t) {
    const h = new Date(t).getHours();
    return h >= 20 || h < 6;
  }

  // svg/data are passed in (rather than read from a fixed #chart-forecast
  // id/forecastReadings global) since the Forecast tab now draws one of
  // these per saved place — see buildForecastCard()/renderForecastCards().
  function drawForecastChart(svg, data) {
    svg.innerHTML = '';
    const W = 1000, H = 240;
    // Extra top margin makes room for the condition-icon strip. Extra right
    // margin (vs. the left) makes room for two label columns sharing that
    // edge - temperature degrees and wind speed - now that wind's carries
    // its "km/h" unit instead of a bare number.
    const marginLeft = 46, marginRight = 76, marginTop = 40, marginBottom = 28;
    const plotW = W - marginLeft - marginRight;
    const plotH = H - marginTop - marginBottom;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

    if (data.length < 2) {
      svg.appendChild(makeEl('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle', 'font-size': 13 })).textContent = 'No forecast data yet';
      return;
    }

    const times = data.map((r) => new Date(r.recorded_at).getTime());
    const temps = data.map((r) => r.temperature_c);
    const hums = data.map((r) => r.humidity_pct);
    const winds = data.map((r) => r.wind_speed_kmh);
    // '|| 0' covers a forecast cache written before rain_mm/snowfall_cm
    // existed (see api/forecast.php) — old cached rows just show no bars
    // rather than breaking the chart until the next Open-Meteo refetch.
    const rains = data.map((r) => r.rain_mm || 0);
    const snows = data.map((r) => r.snowfall_cm || 0);

    const tMin = times[0], tMax = times[times.length - 1];
    // Pad top and bottom by a fraction of the data's own range (with a small
    // floor) rather than a flat 1° - a flat degree barely registers once the
    // forecast spans a wide temperature range, leaving the peak/trough line
    // and its day high/low label looking squished against the plot's edge.
    const tempSpan = Math.max(...temps) - Math.min(...temps) || 1;
    const tempPad = Math.max(2, tempSpan * 0.12);
    const tempMin = Math.floor(Math.min(...temps) - tempPad);
    const tempMax = Math.ceil(Math.max(...temps) + tempPad);
    const humMin = 0, humMax = 100; // full physical range, same convention as the Overview humidity chart
    const windMin = 0, windMax = Math.max(5, Math.ceil(Math.max(...winds) + 2));
    // One gridline/label per whole degree reads fine over a single day but
    // packs together into an unreadable smear once the forecast spans a wide
    // range (a multi-day view easily covers 15-20°) - step so there are
    // about 4-5 lines regardless of range, same approach as the Overview
    // charts' vStep.
    const tempStep = Math.max(1, Math.round((tempMax - tempMin) / 4));

    const x = (t) => marginLeft + ((t - tMin) / (tMax - tMin || 1)) * plotW;
    const yTemp = (v) => marginTop + plotH - ((v - tempMin) / (tempMax - tempMin || 1)) * plotH;
    const yHum = (v) => marginTop + plotH - ((v - humMin) / (humMax - humMin || 1)) * plotH;
    const yWind = (v) => marginTop + plotH - ((v - windMin) / (windMax - windMin || 1)) * plotH;

    const tempColor = cssVar('--temp');
    const humidityColor = cssVar('--humidity');
    const windColor = cssVar('--wind');
    const rainColor = cssVar('--rain');
    const snowColor = cssVar('--snow');

    for (const [a, b] of nightBands(tMin, tMax)) {
      svg.appendChild(makeEl('rect', { x: x(a), y: marginTop, width: Math.max(0, x(b) - x(a)), height: plotH, fill: gridColor(), 'fill-opacity': 0.05 }));
    }

    // Horizontal gridlines - one per tempStep degrees
    for (let v = Math.ceil(tempMin / tempStep) * tempStep; v <= tempMax; v += tempStep) {
      svg.appendChild(makeEl('line', { x1: marginLeft, x2: W - marginRight, y1: yTemp(v), y2: yTemp(v), stroke: gridColor(), 'stroke-opacity': 0.1, 'stroke-width': 1 }));
    }

    // Vertical gridlines + time labels - same stepping logic as the Overview charts
    const rangeHours = (tMax - tMin) / 3600000;
    for (const t of timeAxisTicks(tMin, tMax, plotW)) {
      const xPos = x(t.time);
      svg.appendChild(makeEl('line', { x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom, stroke: gridColor(), 'stroke-opacity': t.major ? 0.3 : 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': 10 })).textContent = t.label;
    }

    // Y-axis labels - temperature (right, alongside its gridlines)
    for (let v = Math.ceil(tempMin / tempStep) * tempStep; v <= tempMax; v += tempStep) {
      svg.appendChild(makeEl('text', { x: W - marginRight + 8, y: yTemp(v) + 4, 'text-anchor': 'start', 'font-size': 10, fill: tempColor })).textContent = v.toFixed(0) + '°';
    }

    // Y-axis labels - wind speed, km/h (far right, fewer ticks to avoid crowding)
    for (let i = 0; i <= 4; i++) {
      const v = windMin + ((windMax - windMin) / 4) * (4 - i);
      const y = marginTop + (plotH / 4) * i;
      svg.appendChild(makeEl('text', { x: W - 4, y: y + 4, 'text-anchor': 'end', 'font-size': 9, fill: windColor })).textContent = v.toFixed(0) + ' km/h';
    }

    // Y-axis labels - humidity (left)
    for (let i = 0; i <= 4; i++) {
      const v = humMin + ((humMax - humMin) / 4) * (4 - i);
      const y = marginTop + (plotH / 4) * i;
      svg.appendChild(makeEl('text', { x: marginLeft - 8, y: y + 4, 'text-anchor': 'end', 'font-size': 10, fill: humidityColor })).textContent = v.toFixed(0) + '%';
    }

    // Rain/snow bars - one hour-wide bar per forecast hour, anchored to the
    // plot's bottom edge and scaled to their own small band there so they
    // read as a strip under the lines rather than competing with them. Rain
    // (mm) and snow (cm) are different units plotted on a shared band purely
    // for a compact visual, not a literal shared scale — each hour's bar is
    // split in half (rain left, snow right) since the two rarely overlap.
    const baselineY = H - marginBottom;
    const precipBandH = plotH * 0.32;
    const precipMax = Math.max(1, Math.max(...rains), Math.max(...snows));
    const yPrecip = (v) => baselineY - Math.min(1, v / precipMax) * precipBandH;
    const hourPx = plotW / Math.max(1, rangeHours);
    const barW = Math.max(1, hourPx - Math.min(2, hourPx * 0.08));
    const subW = barW / 2;

    const precipBars = makeEl('g', { class: 'precip-bars' });
    for (let i = 0; i < data.length; i++) {
      const x0 = x(times[i]);
      if (rains[i] > 0) {
        const barY = yPrecip(rains[i]);
        precipBars.appendChild(makeEl('rect', { x: x0, y: barY, width: subW, height: Math.max(0, baselineY - barY), fill: rainColor, 'fill-opacity': 0.55 }));
      }
      if (snows[i] > 0) {
        const barY = yPrecip(snows[i]);
        precipBars.appendChild(makeEl('rect', { x: x0 + subW, y: barY, width: subW, height: Math.max(0, baselineY - barY), fill: snowColor, 'fill-opacity': 0.7 }));
      }
    }
    svg.appendChild(precipBars);

    // Build path strings — same plain solid-line style as the Overview
    // charts (drawChart()): no area fill, uniform stroke-width, round caps,
    // and a ring+dot marker on the last point of each series. Wind keeps a
    // dash so it stays distinguishable from temp/humidity on the same axes.
    const tempPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yTemp(r.temperature_c).toFixed(1)).join(' ');
    const humPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yHum(r.humidity_pct).toFixed(1)).join(' ');
    const windPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yWind(r.wind_speed_kmh).toFixed(1)).join(' ');

    svg.appendChild(makeEl('path', { d: humPath, fill: 'none', stroke: humidityColor, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
    svg.appendChild(makeEl('path', { d: windPath, fill: 'none', stroke: windColor, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'stroke-dasharray': '4,2' }));
    svg.appendChild(makeEl('path', { d: tempPath, fill: 'none', stroke: tempColor, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));

    const lastT = times[times.length - 1];
    for (const { v, y, color } of [
      { v: temps[temps.length - 1], y: yTemp, color: tempColor },
      { v: hums[hums.length - 1], y: yHum, color: humidityColor },
      { v: winds[winds.length - 1], y: yWind, color: windColor },
    ]) {
      const cx = x(lastT), cy = y(v);
      // 2px surface ring so the end-marker stays legible where lines cross —
      // matches drawChart()'s end-marker treatment on the Overview charts.
      svg.appendChild(makeEl('circle', { cx, cy, r: 5.5, fill: cssVar('--color-bg') }));
      svg.appendChild(makeEl('circle', { cx, cy, r: 4, fill: color }));
    }

    // Daily high/low temperature labels - one pair per calendar day covered
    // by the forecast, printed at that day's peak/trough on the temp line
    // (the usual weather-app convention). tempMin/tempMax already pad the
    // axis beyond the data's own extremes, so the labels never collide with
    // the icon strip above or the time-axis labels below.
    // Horizontally, though, a day's extreme can land right on the series'
    // first/last point - i.e. at the plot's left/right edge, straight under
    // the temperature axis's own per-degree tick labels - so anchor from the
    // edge inward there instead of centering, which would otherwise smear
    // the two labels together (see edgeAnchor()).
    const edgeAnchor = (px) => (px <= marginLeft + 4 ? 'start' : px >= W - marginRight - 4 ? 'end' : 'middle');
    const dayGroups = new Map();
    for (let i = 0; i < data.length; i++) {
      const d = new Date(times[i]);
      const key = d.getFullYear() + '-' + d.getMonth() + '-' + d.getDate();
      if (!dayGroups.has(key)) dayGroups.set(key, []);
      dayGroups.get(key).push(i);
    }
    for (const idxs of dayGroups.values()) {
      let hiI = idxs[0], loI = idxs[0];
      for (const i of idxs) {
        if (temps[i] > temps[hiI]) hiI = i;
        if (temps[i] < temps[loI]) loI = i;
      }
      const hiX = x(times[hiI]), loX = x(times[loI]);
      svg.appendChild(makeEl('text', {
        x: hiX, y: yTemp(temps[hiI]) - 8, 'text-anchor': edgeAnchor(hiX), 'font-size': 10, 'font-weight': 700, fill: tempColor,
      })).textContent = Math.round(temps[hiI]) + '°';
      svg.appendChild(makeEl('text', {
        x: loX, y: yTemp(temps[loI]) + 15, 'text-anchor': edgeAnchor(loX), 'font-size': 10, 'font-weight': 700, fill: tempColor,
      })).textContent = Math.round(temps[loI]) + '°';
    }

    // Weather condition icon strip - one icon per tick, spaced independently
    // from the time-axis labels so long ranges (e.g. 1M/ALL) don't smear
    // icons together.
    const ICON_MIN_PX = 30;
    const iconStepHours = stepHoursForPx(rangeHours, plotW, ICON_MIN_PX);
    const iconTick = new Date(tMin);
    iconTick.setMinutes(0, 0, 0);
    if (iconTick.getTime() < tMin) iconTick.setHours(iconTick.getHours() + 1);
    for (; iconTick.getTime() <= tMax; iconTick.setHours(iconTick.getHours() + iconStepHours)) {
      const t = iconTick.getTime();
      const row = data[nearestIndex(times, t)];
      const iconFile = pickWeatherIcon(row.weather_code, isNightApprox(t));
      svg.appendChild(makeEl('image', { href: 'icon/' + iconFile, x: x(t) - 10, y: 2, width: 20, height: 20, class: 'weather-icon' }));
    }
  }

  // -- Linked crosshair + shared tooltip (temp + humidity charts) -------------
  function hideCrosshair() {
    for (const id of ['chart-temp', 'chart-hum']) {
      const svg = el(id);
      const line = svg && svg.querySelector('.crosshair-line');
      if (line) line.remove();
    }
    el('tooltip').hidden = true;
  }

  function updateCrosshair(t, clientX, clientY) {
    for (const id of ['chart-temp', 'chart-hum']) {
      const geom = chartGeom[id];
      const svg = el(id);
      if (!geom || !svg) continue;
      let line = svg.querySelector('.crosshair-line');
      if (!line) {
        line = makeEl('line', { class: 'crosshair-line', stroke: gridColor(), 'stroke-opacity': 0.4, 'stroke-width': 1 });
        svg.appendChild(line);
      }
      const xPos = geom.marginLeft + ((t - geom.tMin) / (geom.tMax - geom.tMin || 1)) * geom.plotW;
      line.setAttribute('x1', xPos);
      line.setAttribute('x2', xPos);
      line.setAttribute('y1', geom.marginTop);
      line.setAttribute('y2', geom.H - geom.marginBottom);
    }

    const rows = [];
    for (const s of sensors) {
      if (hidden.has(s.id)) continue;
      const pts = series[s.id] || [];
      if (!pts.length) continue;
      const times = pts.map((p) => new Date(p.recorded_at).getTime());
      rows.push({ sensor: s, point: pts[nearestIndex(times, t)] });
    }
    if (!rows.length) { hideCrosshair(); return; }

    el('tooltip-head').textContent = fmtTime(new Date(t).toISOString());
    const rowsBox = el('tooltip-rows');
    rowsBox.innerHTML = '';
    for (const { sensor, point } of rows) {
      const row = document.createElement('div');
      row.className = 'tooltip-row';
      const key = document.createElement('span');
      key.className = 'tooltip-key';
      key.style.background = colorFor(sensor.id);
      const val = document.createElement('span');
      val.className = 'tooltip-val';
      val.textContent = `${point.temperature_c.toFixed(1)}°C / ${point.humidity_pct.toFixed(0)}%`;
      const name = document.createElement('span');
      name.className = 'tooltip-name';
      name.textContent = displayName(sensor);
      if (labelFor(sensor)) name.title = sensor.name;
      row.append(key, val, name);
      rowsBox.appendChild(row);
    }

    const tip = el('tooltip');
    tip.hidden = false;
    const pad = 16;
    const tipWidth = 200;
    let left = clientX + pad;
    if (left + tipWidth > window.innerWidth) left = clientX - tipWidth - pad;
    let top = clientY + pad;
    if (top + rows.length * 18 + 60 > window.innerHeight) top = clientY - rows.length * 18 - 60;
    tip.style.left = Math.max(4, left) + 'px';
    tip.style.top = Math.max(4, top) + 'px';
  }

  function attachCrosshair(svgId) {
    const svg = el(svgId);
    svg.addEventListener('pointermove', (e) => {
      const geom = chartGeom[svgId];
      if (!geom) return;
      const rect = svg.getBoundingClientRect();
      const scale = geom.W / rect.width;
      const xPix = (e.clientX - rect.left) * scale;
      const frac = Math.max(0, Math.min(1, (xPix - geom.marginLeft) / geom.plotW));
      const t = geom.tMin + frac * (geom.tMax - geom.tMin);
      updateCrosshair(t, e.clientX, e.clientY);
    });
    svg.addEventListener('pointerleave', hideCrosshair);
  }

  // -- Settings tab -------------------------------------------------------------
  function renderSettingsCurrent() {
    el('settings-current').textContent =
      `Currently saved — Overview ${currentRange.toUpperCase()} · Forecast ${forecastRange.toUpperCase()}`;
  }

  function showSettingsLoggedIn() {
    settingsLoggedIn = true;
    el('settings-gate').hidden = true;
    el('settings-profile').hidden = false;
    renderSettingsCurrent();
    renderRangesEditor();
    renderLabelList();
    renderPlacesList();
    renderSyncList();
  }

  function showSettingsLoggedOut() {
    settingsLoggedIn = false;
    el('settings-gate').hidden = false;
    el('settings-profile').hidden = true;
    el('ranges-list').innerHTML = '';
    el('label-list').innerHTML = '';

    // Labels are private to the profile just logged out of — drop them and
    // redraw anything that was showing one, back to device names only.
    if (Object.keys(sensorLabels).length) {
      sensorLabels = {};
      renderLegend();
      renderTiles();
      drawTable();
    }

    // Places are private too — drop them and fall back to the Forecast
    // tab's single default card (Brno), reloading it if this profile had
    // actually had places saved.
    const hadPlaces = forecastPlaces.length > 0;
    forecastPlaces = [];
    el('places-list').innerHTML = '';
    el('places-results').hidden = true;
    el('places-results').innerHTML = '';

    // Revert to the fixed default chip set. If either tab's active
    // selection was a custom token that only existed in the profile just
    // logged out of (e.g. "1w"), it wouldn't appear in this list — fall
    // back to 24h rather than leaving no chip highlighted.
    availableRanges = DEFAULT_RANGES.slice();
    let changed = false;
    if (!availableRanges.includes(currentRange)) {
      currentRange = '24h';
      localStorage.setItem(RANGE_STORAGE_KEY, currentRange);
      changed = true;
    }
    if (!availableRanges.includes(forecastRange)) {
      forecastRange = '24h';
      localStorage.setItem(FORECAST_RANGE_STORAGE_KEY, forecastRange);
      changed = true;
    }
    renderChips('range-chips', currentRange);
    renderChips('forecast-range-chips', forecastRange);
    if (changed) {
      loadReadings();
      if (forecastLoaded) loadForecast();
    } else if (hadPlaces && forecastLoaded) {
      loadForecast();
    }
  }

  function settingsError(message) {
    const box = el('settings-error');
    box.textContent = message;
    box.hidden = false;
  }

  // Applies a settings profile's saved state (chip set + which chip is
  // active per tab) — used on login/create, on a ranges edit, and on the
  // initial status check for an already-logged-in browser. Mirrors into
  // localStorage too, so a later logged-out visit (e.g. after Log Out, or
  // in a different browser) starts from the same place instead of jumping
  // back to the hardcoded default.
  function applyRangesFromSettings(settings) {
    if (Array.isArray(settings.ranges) && settings.ranges.length) {
      availableRanges = settings.ranges.slice();
    }
    currentRange = settings.overview_range;
    forecastRange = settings.forecast_range;
    localStorage.setItem(RANGE_STORAGE_KEY, currentRange);
    localStorage.setItem(FORECAST_RANGE_STORAGE_KEY, forecastRange);
    renderChips('range-chips', currentRange);
    renderChips('forecast-range-chips', forecastRange);
    // This profile's own sensor labels — see sensorLabels above.
    sensorLabels = settings.labels || {};
    // ...and its saved forecast places — see forecastPlaces above.
    forecastPlaces = Array.isArray(settings.places) ? settings.places : [];
    renderPlacesList();
  }

  // Fire-and-forget save, called from the range-chip handlers below when
  // logged in. Errors are surfaced quietly (console only) — a failed save
  // shouldn't interrupt browsing, and the chip click already took effect
  // locally (localStorage + the chart redraw) regardless.
  function saveSettingsIfLoggedIn() {
    if (!settingsLoggedIn) return;
    postSettings('save', { overview_range: currentRange, forecast_range: forecastRange })
      .then(() => renderSettingsCurrent())
      .catch((err) => console.error('Failed to save settings:', err.message));
  }

  async function initSettingsStatus() {
    try {
      const payload = await postSettings('status', {});
      if (payload.loggedIn) {
        applyRangesFromSettings(payload.settings);
        showSettingsLoggedIn();
      }
    } catch (err) {
      console.error('Failed to check settings status:', err.message);
    }
  }

  el('settings-login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    el('settings-error').hidden = true;
    const password = el('settings-password').value;
    try {
      const payload = await postSettings('login', { password });
      applyRangesFromSettings(payload.settings);
      showSettingsLoggedIn();
      el('settings-password').value = '';
      loadReadings();
      if (forecastLoaded) loadForecast();
    } catch (err) {
      settingsError(err.message);
    }
  });

  el('settings-create-btn').addEventListener('click', async () => {
    el('settings-error').hidden = true;
    const password = el('settings-password').value;
    try {
      const payload = await postSettings('create', {
        password,
        overview_range: currentRange,
        forecast_range: forecastRange,
      });
      applyRangesFromSettings(payload.settings);
      showSettingsLoggedIn();
      el('settings-password').value = '';
    } catch (err) {
      settingsError(err.message);
    }
  });

  el('settings-logout-btn').addEventListener('click', async () => {
    try {
      await postSettings('logout', {});
    } catch (err) {
      console.error('Failed to log out cleanly:', err.message);
    }
    showSettingsLoggedOut();
  });

  // -- Time-span editor (add/remove/reorder availableRanges) ------------------
  // Only shown logged in — editing has nowhere to save to otherwise. Every
  // mutation saves immediately (no separate "Save" button), matching how a
  // chip click already auto-saves elsewhere in this tab.
  function renderRangesEditor() {
    const list = el('ranges-list');
    list.innerHTML = '';
    availableRanges.forEach((token, i) => {
      const li = document.createElement('li');
      li.className = 'ranges-item';

      const label = document.createElement('span');
      label.className = 'ranges-item-label';
      label.textContent = token.toUpperCase();
      li.appendChild(label);

      const up = document.createElement('button');
      up.type = 'button';
      up.className = 'ranges-item-btn';
      up.dataset.action = 'up';
      up.dataset.index = String(i);
      up.disabled = i === 0;
      up.title = 'Move earlier';
      up.textContent = '▲';

      const down = document.createElement('button');
      down.type = 'button';
      down.className = 'ranges-item-btn';
      down.dataset.action = 'down';
      down.dataset.index = String(i);
      down.disabled = i === availableRanges.length - 1;
      down.title = 'Move later';
      down.textContent = '▼';

      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'ranges-item-btn remove';
      remove.dataset.action = 'remove';
      remove.dataset.index = String(i);
      remove.disabled = availableRanges.length <= 1;
      remove.title = 'Remove';
      remove.textContent = '✕';

      li.append(up, down, remove);
      list.appendChild(li);
    });
  }

  // Posts a full replacement list to settings.php and applies whatever it
  // hands back (it may auto-correct overview_range/forecast_range if the
  // edit removed the one currently active). Callers attach their own
  // .catch() for how to surface a failure.
  function saveRanges(newList) {
    el('ranges-error').hidden = true;
    return postSettings('save_ranges', { ranges: newList }).then((payload) => {
      applyRangesFromSettings(payload.settings);
      renderSettingsCurrent();
      renderRangesEditor();
      loadReadings();
      if (forecastLoaded) loadForecast();
    });
  }

  function rangesEditorError(message) {
    const box = el('ranges-error');
    box.textContent = message;
    box.hidden = false;
  }

  el('ranges-list').addEventListener('click', (e) => {
    const btn = e.target.closest('.ranges-item-btn');
    if (!btn || btn.disabled) return;
    const i = Number(btn.dataset.index);
    const next = availableRanges.slice();
    if (btn.dataset.action === 'remove') {
      next.splice(i, 1);
    } else if (btn.dataset.action === 'up' && i > 0) {
      [next[i - 1], next[i]] = [next[i], next[i - 1]];
    } else if (btn.dataset.action === 'down' && i < next.length - 1) {
      [next[i], next[i + 1]] = [next[i + 1], next[i]];
    } else {
      return;
    }
    saveRanges(next).catch((err) => rangesEditorError(err.message));
  });

  // Same token shape as api/settings.php's validRangeToken() — checked
  // client-side too so an obviously malformed entry doesn't round-trip to
  // the server just to be rejected.
  const RANGE_TOKEN_RE = /^(all|[1-9]\d{0,2}(h|d|w|m))$/;

  // -- Sensor labels (per-sensor friendly name, shown on Overview) ------------
  // Only shown logged in, same as the ranges editor and sync list below —
  // but unlike those, a label is private to this profile (settings.php's
  // `sensor_labels`), not the one shared `sensors` registry. Not rebuilt on
  // every loadReadings() poll (unlike renderSyncList()) so an in-progress
  // edit in one of these inputs is never clobbered out from under someone
  // typing.
  function renderLabelList() {
    const list = el('label-list');
    if (!list) return;
    list.innerHTML = '';
    sensors.forEach((s) => {
      const li = document.createElement('li');
      li.className = 'label-item';

      const name = document.createElement('span');
      name.className = 'label-item-name';
      name.textContent = s.name;

      const input = document.createElement('input');
      input.type = 'text';
      input.className = 'settings-input label-item-input';
      input.maxLength = 40;
      input.placeholder = 'e.g. Kitchen';
      input.value = sensorLabels[s.name] || '';
      input.dataset.sensor = s.name;

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'label-item-btn';
      btn.textContent = 'Save';

      const result = document.createElement('div');
      result.className = 'label-item-result';
      result.hidden = true;

      li.append(name, input, btn, result);
      list.appendChild(li);
    });
  }

  async function saveSensorLabel(li) {
    const input = li.querySelector('.label-item-input');
    const btn = li.querySelector('.label-item-btn');
    const result = li.querySelector('.label-item-result');
    const sensorName = input.dataset.sensor;
    const label = input.value.trim();

    btn.disabled = true;
    result.hidden = true;
    result.className = 'label-item-result';
    try {
      const payload = await postSettings('save_sensor_label', { sensor: sensorName, label });
      // Reflect the saved value into local state and every place on Overview
      // that shows sensor identity, without waiting for the next poll.
      if (payload.label) {
        sensorLabels[sensorName] = payload.label;
      } else {
        delete sensorLabels[sensorName];
      }
      input.value = payload.label || '';
      result.textContent = payload.label ? `Saved — Overview now shows "${payload.label}".` : 'Saved — Overview shows the device name again.';
      result.classList.add('ok');
      renderLegend();
      renderTiles();
      drawTable();
    } catch (err) {
      result.textContent = err.message;
      result.classList.add('error');
    } finally {
      result.hidden = false;
      btn.disabled = false;
    }
  }

  el('label-list').addEventListener('click', (e) => {
    const btn = e.target.closest('.label-item-btn');
    if (!btn || btn.disabled) return;
    saveSensorLabel(btn.closest('.label-item'));
  });

  // Enter in a label input saves it too, without needing to reach for the button.
  el('label-list').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const input = e.target.closest('.label-item-input');
    if (!input) return;
    e.preventDefault();
    saveSensorLabel(input.closest('.label-item'));
  });

  // -- Forecast places (Settings tab, Forecast section) ------------------------
  // Only shown logged in, same as the ranges editor and sensor labels above
  // — a place saved here is private to this profile (settings.php's
  // `forecast_places`), unlike the shared `sensors` registry the Sensors
  // section below lists. See forecastPlaces/forecastTargets() above and
  // applyRangesFromSettings(), which is what actually keeps this list in
  // sync with the server after every mutation here. The Forecast tab plots
  // every row shown here, in this same order (or a single default "Brno"
  // card when there are none) — there's no "active" place to pick, just
  // what to add/remove/reorder.
  function renderPlacesList() {
    const list = el('places-list');
    if (!list) return;
    list.innerHTML = '';
    if (!forecastPlaces.length) {
      const li = document.createElement('li');
      li.className = 'settings-status';
      li.style.margin = '0';
      li.textContent = 'No places saved yet — the Forecast tab shows Brno by default.';
      list.appendChild(li);
      return;
    }
    forecastPlaces.forEach((p, i) => {
      const li = document.createElement('li');
      li.className = 'places-item';

      const name = document.createElement('span');
      name.className = 'places-item-name';
      name.textContent = p.name;

      const coords = document.createElement('span');
      coords.className = 'places-item-coords';
      coords.textContent = `${p.latitude.toFixed(2)}, ${p.longitude.toFixed(2)}`;

      const up = document.createElement('button');
      up.type = 'button';
      up.className = 'places-item-move-btn';
      up.dataset.action = 'up';
      up.dataset.index = String(i);
      up.disabled = i === 0;
      up.title = 'Move up';
      up.textContent = '▲';

      const down = document.createElement('button');
      down.type = 'button';
      down.className = 'places-item-move-btn';
      down.dataset.action = 'down';
      down.dataset.index = String(i);
      down.disabled = i === forecastPlaces.length - 1;
      down.title = 'Move down';
      down.textContent = '▼';

      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'places-item-btn remove';
      remove.dataset.action = 'remove';
      remove.dataset.id = String(p.id);
      remove.title = 'Remove';
      remove.textContent = '✕';

      li.append(name, coords, up, down, remove);
      list.appendChild(li);
    });
  }

  function placesError(message) {
    const box = el('places-error');
    box.textContent = message;
    box.hidden = false;
  }

  // Applies the fresh `settings` a places mutation (add/remove/reorder)
  // handed back, then reloads the Forecast tab if it's ever been opened —
  // the set or order of places (and so which cards are shown, in what
  // order) just changed.
  function applyPlacesResult(payload) {
    el('places-error').hidden = true;
    applyRangesFromSettings(payload.settings);
    if (forecastLoaded) loadForecast();
  }

  async function removePlace(id) {
    try {
      applyPlacesResult(await postSettings('remove_place', { id }));
    } catch (err) {
      placesError(err.message);
    }
  }

  async function addPlace(name, latitude, longitude) {
    try {
      applyPlacesResult(await postSettings('add_place', { name, latitude, longitude }));
      el('places-results').hidden = true;
      el('places-results').innerHTML = '';
      el('places-search-input').value = '';
    } catch (err) {
      placesError(err.message);
    }
  }

  // Posts the full reordered id list, same "whole list every time" shape
  // as saveRanges() above — settings.php rejects anything that isn't
  // exactly this profile's current ids, just reordered.
  async function reorderPlaces(newOrder) {
    try {
      applyPlacesResult(await postSettings('reorder_places', { ids: newOrder.map((p) => p.id) }));
    } catch (err) {
      placesError(err.message);
    }
  }

  el('places-list').addEventListener('click', (e) => {
    const btn = e.target.closest('.places-item-btn, .places-item-move-btn');
    if (!btn || btn.disabled) return;
    if (btn.dataset.action === 'up' || btn.dataset.action === 'down') {
      const i = Number(btn.dataset.index);
      const next = forecastPlaces.slice();
      if (btn.dataset.action === 'up' && i > 0) {
        [next[i - 1], next[i]] = [next[i], next[i - 1]];
      } else if (btn.dataset.action === 'down' && i < next.length - 1) {
        [next[i], next[i + 1]] = [next[i + 1], next[i]];
      } else {
        return;
      }
      reorderPlaces(next);
      return;
    }
    removePlace(Number(btn.dataset.id));
  });

  // Renders api/geocode.php's search results as a pick list — each one an
  // "Add" button carrying its name/latitude/longitude in data attributes,
  // so clicking it doesn't need a second round trip to know what it's
  // adding.
  function renderPlacesResults(results) {
    const list = el('places-results');
    list.innerHTML = '';
    results.forEach((r) => {
      const li = document.createElement('li');
      li.className = 'places-result-item';

      const name = document.createElement('span');
      name.className = 'places-result-name';
      name.textContent = r.name;

      const add = document.createElement('button');
      add.type = 'button';
      add.className = 'places-item-btn';
      add.dataset.name = r.name;
      add.dataset.lat = String(r.latitude);
      add.dataset.lon = String(r.longitude);
      add.textContent = 'Add';

      li.append(name, add);
      list.appendChild(li);
    });
    list.hidden = results.length === 0;
  }

  el('places-search-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    el('places-error').hidden = true;
    const input = el('places-search-input');
    const q = input.value.trim();
    if (!q) return;
    try {
      const payload = await fetchJson(`${GEOCODE_URL}?q=${encodeURIComponent(q)}`);
      const results = payload.results || [];
      if (!results.length) {
        placesError(`No places found for "${q}".`);
        el('places-results').hidden = true;
        return;
      }
      renderPlacesResults(results);
    } catch (err) {
      placesError(err.message);
    }
  });

  el('places-results').addEventListener('click', (e) => {
    const btn = e.target.closest('.places-item-btn');
    if (!btn) return;
    addPlace(btn.dataset.name, Number(btn.dataset.lat), Number(btn.dataset.lon));
  });

  // Renders seconds-since-boot (sensors.uptime_seconds, from
  // uptime_reporter.py — see db/database/sensors/tables/sensors.md) as a
  // compact "3d 4h" / "5h 12m" / "42m" string. Coarsest-two-units only —
  // this is a Settings-tab glance, not a stopwatch.
  function formatUptime(seconds) {
    if (seconds === null || seconds === undefined) return 'no uptime on file';
    seconds = Math.max(0, Math.floor(seconds));
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `up ${days}d ${hours}h`;
    if (hours > 0) return `up ${hours}h ${minutes}m`;
    return `up ${minutes}m`;
  }

  // Renders the currently-deployed git commit (sensors.commit_hash/
  // commit_summary/commit_date, from report_version.py — see
  // db/database/sensors/tables/sensors.md) as a compact "abc1234 · Fix
  // thing · Sep 5" string. All three land together or not at all (see that
  // reporter), so this only checks commit_hash.
  function formatVersion(s) {
    if (!s.commit_hash) return 'no version on file';
    const date = s.commit_date
      ? new Date(s.commit_date).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
      : null;
    return [s.commit_hash, s.commit_summary, date].filter(Boolean).join(' · ');
  }

  // Renders the raw INA219 readings behind `status` (sensors.battery_voltage_v/
  // battery_current_ma/battery_power_w, from ups_ina219.py — see
  // db/database/sensors/tables/sensors.md) as a compact "12.34 V · -123.4 mA
  // · 1.52 W" string — the numbers behind the OK/CHARGING/BATTERY badge shown
  // on the Overview tab's tiles. All three land together or not at all (same
  // UPS-HAT-fitted condition as `status`), so this only checks
  // battery_voltage_v. Returns null (rather than a placeholder string) for a
  // sensor with no UPS HAT, so the caller can skip the field entirely.
  function formatBattery(s) {
    if (s.battery_voltage_v === null || s.battery_voltage_v === undefined) return null;
    const parts = [`${s.battery_voltage_v.toFixed(2)} V`];
    if (s.battery_current_ma !== null) parts.push(`${s.battery_current_ma.toFixed(1)} mA`);
    if (s.battery_power_w !== null) parts.push(`${s.battery_power_w.toFixed(2)} W`);
    return parts.join(' · ');
  }

  // -- Manual sync + deploy triggers ("Sync Now" / "Update Now") --------------
  // "Sync Now" is only meaningful for a Pi Zero that's fallen behind (e.g.
  // taken offline on battery) — see api/sync_trigger.php and
  // rpi-zero/web/sync.php, which this actually calls. "Update Now" pulls +
  // redeploys that one sensor on demand — see api/deploy_trigger.php and
  // rpi-zero/web/deploy_trigger.php — for a sensor that missed the
  // automatic fleet-wide relay a push normally triggers (api/deploy_webhook.php),
  // or one you don't want to wait on. Both shown regardless of online/offline
  // status: the whole point of either is usually catching a sensor up right
  // after (or before) it comes back.
  // Also doubles as the Sensors section's uptime + deployed-version display
  // (sensors.uptime_seconds from uptime_reporter.py, sensors.commit_hash/
  // commit_summary/commit_date from report_version.py) — same per-sensor
  // row, no need for a second/third list.
  function renderSyncList() {
    const list = el('sync-list');
    if (!list) return;
    list.innerHTML = '';
    sensors.forEach((s) => {
      const li = document.createElement('li');
      li.className = 'sync-item' + (s.online ? '' : ' offline');

      const header = document.createElement('div');
      header.className = 'sync-item-header';

      const name = document.createElement('span');
      name.className = 'sync-item-name';
      name.textContent = s.name;

      const badges = document.createElement('span');
      badges.className = 'sync-item-badges';

      const connBadge = document.createElement('span');
      connBadge.className = 'sync-item-badge';
      connBadge.textContent = s.online ? 'ONLINE' : 'OFFLINE';
      if (s.last_ping_at) connBadge.title = 'Last ping ' + fmtRelative(s.last_ping_at);
      badges.appendChild(connBadge);

      if (s.dht22_fault) {
        const faultBadge = document.createElement('span');
        faultBadge.className = 'sync-item-badge fault';
        faultBadge.textContent = 'FAULTY DHT22';
        if (s.dht22_fault_since) faultBadge.title = 'Failing to read since ' + fmtRelative(s.dht22_fault_since);
        badges.appendChild(faultBadge);
      }

      header.append(name, badges);

      const info = document.createElement('div');
      info.className = 'sync-item-info';

      const version = document.createElement('span');
      version.className = 'sync-item-field-value';
      version.textContent = formatVersion(s);
      version.title = s.commit_summary || '';

      info.append(
        makeSyncField('IP address', s.ip_address || 'no IP on file'),
        makeSyncField('Uptime', formatUptime(s.uptime_seconds)),
        makeSyncField('Git version', version),
      );

      const battery = formatBattery(s);
      if (battery) info.append(makeSyncField('Battery', battery));

      const actions = document.createElement('div');
      actions.className = 'sync-item-actions';

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'sync-item-btn';
      btn.dataset.sensor = s.name;
      btn.textContent = 'Sync Now';

      const deployBtn = document.createElement('button');
      deployBtn.type = 'button';
      deployBtn.className = 'sync-item-deploy-btn';
      deployBtn.dataset.sensor = s.name;
      deployBtn.textContent = 'Update Now';

      actions.append(btn, deployBtn);

      const result = document.createElement('div');
      result.className = 'sync-item-result';
      result.hidden = true;

      li.append(header, info, actions, result);
      list.appendChild(li);
    });
  }

  // Builds one "label: value" field for the Sensors section's info block.
  // `value` may be a plain string or an already-built element (e.g. the
  // Git version span, which carries a title tooltip).
  function makeSyncField(label, value) {
    const field = document.createElement('div');
    field.className = 'sync-item-field';

    const labelEl = document.createElement('span');
    labelEl.className = 'sync-item-field-label';
    labelEl.textContent = label;

    const valueEl = (typeof value === 'string')
      ? document.createElement('span')
      : value;
    if (typeof value === 'string') {
      valueEl.textContent = value;
    }
    valueEl.classList.add('sync-item-field-value');

    field.append(labelEl, valueEl);
    return field;
  }

  el('sync-list').addEventListener('click', async (e) => {
    const btn = e.target.closest('.sync-item-btn');
    if (!btn || btn.disabled) return;
    const sensorName = btn.dataset.sensor;
    const result = btn.closest('.sync-item').querySelector('.sync-item-result');

    btn.disabled = true;
    const prevLabel = btn.textContent;
    btn.textContent = 'Syncing…';
    result.hidden = true;
    result.className = 'sync-item-result';

    try {
      const payload = await postJson(SYNC_TRIGGER_URL, { sensor: sensorName });
      result.textContent = (payload.ok ? payload.output : (payload.error || payload.output)) || 'Done, no output.';
      result.classList.add(payload.ok ? 'ok' : 'error');
    } catch (err) {
      result.textContent = err.message;
      result.classList.add('error');
    } finally {
      result.hidden = false;
      btn.disabled = false;
      btn.textContent = prevLabel;
    }
  });

  el('sync-list').addEventListener('click', async (e) => {
    const btn = e.target.closest('.sync-item-deploy-btn');
    if (!btn || btn.disabled) return;
    const sensorName = btn.dataset.sensor;
    const result = btn.closest('.sync-item').querySelector('.sync-item-result');

    btn.disabled = true;
    const prevLabel = btn.textContent;
    btn.textContent = 'Updating…';
    result.hidden = true;
    result.className = 'sync-item-result';

    try {
      const payload = await postJson(DEPLOY_TRIGGER_URL, { sensor: sensorName });
      result.textContent = (payload.ok ? payload.output : (payload.error || payload.output)) || 'Done, no output.';
      result.classList.add(payload.ok ? 'ok' : 'error');
      // Not forcing a reload here (unlike, say, saveSensorLabel) — the
      // updated commit_hash/commit_summary/commit_date show up on the next
      // regular loadReadings() poll (REFRESH_MS), same as Sync Now above
      // leaves the uptime/reading refresh to that same poll.
    } catch (err) {
      result.textContent = err.message;
      result.classList.add('error');
    } finally {
      result.hidden = false;
      btn.disabled = false;
      btn.textContent = prevLabel;
    }
  });

  el('ranges-add-form').addEventListener('submit', (e) => {
    e.preventDefault();
    el('ranges-error').hidden = true;
    const input = el('ranges-add-input');
    const token = input.value.trim().toLowerCase();
    if (!RANGE_TOKEN_RE.test(token)) {
      rangesEditorError('Use a number plus h/d/w/m (e.g. 6h, 3d, 1w, 2m), or "all".');
      return;
    }
    if (availableRanges.includes(token)) {
      rangesEditorError('That time span is already in the list.');
      return;
    }
    if (availableRanges.length >= 12) {
      rangesEditorError('At most 12 time spans are allowed.');
      return;
    }
    saveRanges([...availableRanges, token])
      .then(() => { input.value = ''; })
      .catch((err) => rangesEditorError(err.message));
  });

  // -- Range chips --------------------------------------------------------------
  // Both rows are built from the same availableRanges list (the fixed
  // DEFAULT_RANGES when logged out, or the logged-in profile's own edited
  // list — see the Settings tab). Click handling is delegated to each
  // container, so it keeps working unchanged as chips are added/removed/
  // reordered and the buttons underneath get rebuilt.
  function renderChips(containerId, activeValue) {
    const box = el(containerId);
    box.innerHTML = '';
    availableRanges.forEach((token) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'chip' + (token === activeValue ? ' active' : '');
      btn.dataset.range = token;
      btn.textContent = token.toUpperCase();
      box.appendChild(btn);
    });
  }

  // Scoped to each panel's own chip group — #range-chips and
  // #forecast-range-chips both use the shared .chip class, so a global
  // querySelectorAll('.chip') here would also clear the other panel's
  // selection.
  document.getElementById('range-chips').addEventListener('click', (e) => {
    const btn = e.target.closest('.chip');
    if (!btn) return;
    document.querySelectorAll('#range-chips .chip').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    currentRange = btn.dataset.range;
    localStorage.setItem(RANGE_STORAGE_KEY, currentRange);
    saveSettingsIfLoggedIn();
    loadReadings();
  });

  document.getElementById('forecast-range-chips').addEventListener('click', (e) => {
    const btn = e.target.closest('.chip');
    if (!btn) return;
    document.querySelectorAll('#forecast-range-chips .chip').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    forecastRange = btn.dataset.range;
    localStorage.setItem(FORECAST_RANGE_STORAGE_KEY, forecastRange);
    saveSettingsIfLoggedIn();
    loadForecast();
  });

  renderChips('range-chips', currentRange);
  renderChips('forecast-range-chips', forecastRange);

  // -- Settings sections -----------------------------------------------------
  document.getElementById('settings-nav').addEventListener('click', (e) => {
    const btn = e.target.closest('.settings-nav-item');
    if (!btn) return;
    const section = btn.dataset.section;
    document.querySelectorAll('.settings-nav-item').forEach((b) => b.classList.toggle('active', b === btn));
    document.querySelectorAll('.settings-section').forEach((p) => { p.hidden = p.dataset.section !== section; });
  });

  // -- Tabs -----------------------------------------------------------------
  // The Forecast tab's data is fetched lazily, the first time it's opened,
  // so a visit that never leaves Overview costs nothing extra against
  // Open-Meteo.
  document.getElementById('tabs').addEventListener('click', (e) => {
    const btn = e.target.closest('.tab');
    if (!btn) return;
    const tab = btn.dataset.tab;
    document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b === btn));
    document.querySelectorAll('.tab-panel').forEach((p) => { p.hidden = p.dataset.panel !== tab; });
    if (tab === 'forecast' && !forecastLoaded) {
      forecastLoaded = true;
      loadForecast();
      setInterval(loadForecast, FORECAST_REFRESH_MS);
    }
  });

  attachCrosshair('chart-temp');
  attachCrosshair('chart-hum');

  // Check for an already-logged-in settings profile (a returning browser's
  // session cookie) before the first load, so its saved ranges are used as
  // the actual starting point rather than flashing the localStorage/default
  // range first. Never blocks the dashboard on this — a failed/slow check
  // just falls through to whatever was already in localStorage.
  initSettingsStatus().finally(() => {
    loadReadings();
    loadDaily();
  });
  setInterval(loadReadings, REFRESH_MS);
  setInterval(loadDaily, REFRESH_MS * 15); // 12-month aggregates barely change minute to minute
  setInterval(renderStatus, 1000);
})();
