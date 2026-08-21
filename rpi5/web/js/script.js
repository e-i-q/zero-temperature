(function () {
  const READINGS_URL = 'api/readings.php';
  const DAILY_URL = 'api/daily.php';
  const REFRESH_MS = 60000; // poll for new data every minute
  const RANGE_STORAGE_KEY = 'hiveRange';
  const MAX_CHART_POINTS = 1500; // per-sensor downsample cap for the two timeline charts
  const GRID_COLOR = '#1d1f20'; // --color-text, used for hairline gridlines/night bands

  const ns = 'http://www.w3.org/2000/svg';
  const el = (id) => document.getElementById(id);
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
  let sensors = [];        // [{id, name, description, online, latest, stats}]
  let series = {};         // { sensorId: [{recorded_at, temperature_c, humidity_pct, sample_count}] }
  let dailySeries = {};    // { sensorId: [{day, temp_avg, temp_min, temp_max}] }
  let hidden = new Set();  // sensor ids toggled off via the legend
  let statusLabel = 'Loading…';
  let nextFetchAt = Date.now() + REFRESH_MS;
  let chartGeom = {};      // svgId -> x/y mapping of its last render, for the linked crosshair

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

  async function loadReadings() {
    nextFetchAt = Date.now() + REFRESH_MS;
    try {
      const payload = await fetchJson(`${READINGS_URL}?range=${encodeURIComponent(currentRange)}`);
      sensors = payload.sensors || [];
      series = payload.series || {};
      hidden = new Set([...hidden].filter((id) => sensors.some((s) => s.id === id)));
      statusLabel = sensors.some((s) => s.online) ? 'Live' : 'No sensor online';
      renderAll(payload);
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

  // Averages each sensor's own recent trend rather than diffing the average
  // series, so a sensor that drops out mid-window doesn't skew the read.
  function getAvgTempTrend() {
    const diffs = [];
    for (const s of sensors) {
      const pts = series[s.id];
      if (!pts || pts.length < 2) continue;
      const n = Math.min(TREND_SAMPLE_COUNT, pts.length);
      const recent = pts.slice(-n);
      diffs.push(recent[recent.length - 1].temperature_c - recent[0].temperature_c);
    }
    if (!diffs.length) return null;
    const diff = diffs.reduce((a, b) => a + b, 0) / diffs.length;
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
      label.textContent = s.name; // sensor names come from the DB — textContent, never innerHTML
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
      const name = document.createElement('span');
      name.className = 'tile-name';
      name.textContent = s.name;
      const badge = document.createElement('span');
      badge.className = 'tile-badge';
      badge.textContent = s.online ? 'OK' : 'OFFLINE';
      head.append(name, badge);
      tile.appendChild(head);

      const value = document.createElement('div');
      value.className = 'tile-value';
      if (s.latest) {
        const num = document.createElement('span');
        num.textContent = s.latest.temperature_c.toFixed(1);
        const unit = document.createElement('span');
        unit.className = 'unit';
        unit.textContent = '°C';
        value.append(num, unit);
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
      nameSpan.textContent = sensor.name;
      tdSensor.append(sw, nameSpan);
      const tdTemp = document.createElement('td');
      tdTemp.textContent = point.temperature_c.toFixed(1);
      const tdHum = document.createElement('td');
      tdHum.textContent = point.humidity_pct.toFixed(1);
      const tdSamples = document.createElement('td');
      tdSamples.textContent = point.sample_count;
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

  function hourTickStep(rangeHours, plotW) {
    const HOUR_STEPS = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168, 336, 720, 1440];
    for (const step of HOUR_STEPS) {
      const labelWidthPx = step >= 24 ? 54 : 14;
      const maxTicks = Math.max(2, Math.floor(plotW / labelWidthPx));
      if (rangeHours / step <= maxTicks) return step;
    }
    return HOUR_STEPS[HOUR_STEPS.length - 1];
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
      svg.appendChild(makeEl('rect', { x: x(a), y: marginTop, width: Math.max(0, x(b) - x(a)), height: plotH, fill: GRID_COLOR, 'fill-opacity': 0.05 }));
    }

    const vStepRaw = (vMax - vMin) / 4;
    const vStep = isTemp ? Math.max(1, Math.round(vStepRaw)) : Math.max(5, Math.round(vStepRaw / 5) * 5);
    for (let v = Math.ceil(vMin / vStep) * vStep; v <= vMax; v += vStep) {
      svg.appendChild(makeEl('line', { x1: marginLeft, x2: W - marginRight, y1: y(v), y2: y(v), stroke: GRID_COLOR, 'stroke-opacity': 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: marginLeft - 8, y: y(v) + 4, 'text-anchor': 'end', 'font-size': 10 })).textContent = isTemp ? v.toFixed(0) + '°' : v.toFixed(0) + unit;
    }

    const rangeHours = (tMax - tMin) / 3600000;
    const stepHours = hourTickStep(rangeHours, plotW);
    const tick = new Date(tMin);
    tick.setMinutes(0, 0, 0);
    if (tick.getTime() < tMin) tick.setHours(tick.getHours() + 1);
    for (; tick.getTime() <= tMax; tick.setHours(tick.getHours() + stepHours)) {
      const xPos = x(tick.getTime());
      const isMidnight = tick.getHours() === 0;
      svg.appendChild(makeEl('line', { x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom, stroke: GRID_COLOR, 'stroke-opacity': isMidnight ? 0.3 : 0.1, 'stroke-width': 1 }));
      const label = (stepHours >= 24 || isMidnight) ? tick.toLocaleString(undefined, { month: 'short', day: 'numeric' }) : String(tick.getHours()).padStart(2, '0');
      svg.appendChild(makeEl('text', { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': 10 })).textContent = label;
    }

    for (const { sensor, points } of perSensor) {
      const color = colorFor(sensor.id);
      const d = points.map((p, i) => (i === 0 ? 'M' : 'L') + x(new Date(p.recorded_at).getTime()).toFixed(1) + ',' + y(p[valueKey]).toFixed(1)).join(' ');
      svg.appendChild(makeEl('path', { d, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', opacity: sensor.online ? 1 : 0.55 }));
      const last = points[points.length - 1];
      const cx = x(new Date(last.recorded_at).getTime()), cy = y(last[valueKey]);
      // 2px surface ring so the end-marker stays legible where lines cross
      svg.appendChild(makeEl('circle', { cx, cy, r: 5.5, fill: '#f2f2f3' }));
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
      svg.appendChild(makeEl('line', { x1: marginLeft, x2: W - marginRight, y1: y(v), y2: y(v), stroke: GRID_COLOR, 'stroke-opacity': 0.1, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: marginLeft - 8, y: y(v) + 4, 'text-anchor': 'end', 'font-size': 10 })).textContent = v.toFixed(0) + '°';
    }

    const monthTick = new Date(tMin);
    monthTick.setDate(1);
    monthTick.setHours(0, 0, 0, 0);
    if (monthTick.getTime() < tMin) monthTick.setMonth(monthTick.getMonth() + 1);
    for (; monthTick.getTime() <= tMax; monthTick.setMonth(monthTick.getMonth() + 1)) {
      const xPos = x(monthTick.getTime());
      svg.appendChild(makeEl('line', { x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom, stroke: GRID_COLOR, 'stroke-opacity': 0.15, 'stroke-width': 1 }));
      svg.appendChild(makeEl('text', { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': 10 })).textContent = monthTick.toLocaleString(undefined, { month: 'short' });
    }

    for (const s of visible) {
      const color = colorFor(s.id);
      const pts = dailySeries[s.id];
      const d = pts.map((p, i) => (i === 0 ? 'M' : 'L') + x(new Date(p.day + 'T00:00:00').getTime()).toFixed(1) + ',' + y(p.temp_avg).toFixed(1)).join(' ');
      svg.appendChild(makeEl('path', { d, fill: 'none', stroke: color, 'stroke-width': 1.75, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
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
        line = makeEl('line', { class: 'crosshair-line', stroke: GRID_COLOR, 'stroke-opacity': 0.4, 'stroke-width': 1 });
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
      name.textContent = sensor.name;
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

  // -- Range chips --------------------------------------------------------------
  document.getElementById('range-chips').addEventListener('click', (e) => {
    const btn = e.target.closest('.chip');
    if (!btn) return;
    document.querySelectorAll('.chip').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    currentRange = btn.dataset.range;
    localStorage.setItem(RANGE_STORAGE_KEY, currentRange);
    loadReadings();
  });
  document.querySelectorAll('.chip').forEach((b) => b.classList.toggle('active', b.dataset.range === currentRange));

  attachCrosshair('chart-temp');
  attachCrosshair('chart-hum');

  loadReadings();
  loadDaily();
  setInterval(loadReadings, REFRESH_MS);
  setInterval(loadDaily, REFRESH_MS * 15); // 12-month aggregates barely change minute to minute
  setInterval(renderStatus, 1000);
})();
