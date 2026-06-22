(function () {
  const DATA_URL = 'readings.php';
  const REFRESH_MS = 60000; // poll for new data every minute

  let allReadings = [];
  let sunTimes = {};
  let currentRangeHours = 24;
  let statusLabel = 'Loading…';
  let nextFetchAt = Date.now() + REFRESH_MS;

  const el = (id) => document.getElementById(id);
  const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function fmtTime(iso) {
    const d = new Date(iso);
    return d.toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false
    });
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

  async function loadData() {
    nextFetchAt = Date.now() + REFRESH_MS;
    try {
      // ALL maps to a generously large window; PHP endpoint clamps to a sane max server-side.
      const requestHours = currentRangeHours >= 999999 ? 8760 : currentRangeHours;
      const url = `${DATA_URL}?hours=${requestHours}`;
      const res = await fetch(url, { cache: 'no-store' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const payload = await res.json();
      allReadings = payload.readings || [];
      sunTimes = payload.sun_times || {};
      render(payload);
    } catch (err) {
      statusLabel = 'Unable to load data';
      renderCountdown();
      console.error('Failed to load readings:', err);
    }
  }

  function renderCountdown() {
    const secsLeft = Math.max(0, Math.round((nextFetchAt - Date.now()) / 1000));
    el('last-updated').textContent = `${statusLabel} · next refresh in ${secsLeft}s`;
  }

  function render(payload) {
    const empty = el('empty-state');
    const hero = el('hero');
    const chartFrame = document.querySelector('.chart-frame');
    const legend = document.querySelector('.legend');
    const tableSection = el('log-table').parentElement;

    if (!allReadings.length) {
      empty.style.display = 'block';
      hero.style.display = 'none';
      chartFrame.style.display = 'none';
      legend.style.display = 'none';
      el('log-table').style.display = 'none';
      statusLabel = 'No data';
      renderCountdown();
      return;
    }

    empty.style.display = 'none';
    hero.style.display = 'grid';
    chartFrame.style.display = 'block';
    legend.style.display = 'flex';
    el('log-table').style.display = 'table';

    const latest = payload.latest || allReadings[allReadings.length - 1];
    document.title = latest.temperature_c.toFixed(1) + '°C · Zero Temperature';
    el('current-temp').innerHTML = latest.temperature_c.toFixed(1) + '<span class="hero-unit">°C</span><span class="trend-badge" id="temp-trend"></span>';
    el('current-humidity').innerHTML = latest.humidity_pct.toFixed(1) + '<span class="hero-unit">%</span>';
    el('temp-meta').textContent = fmtTime(latest.recorded_at) + ' — ' + fmtRelative(latest.recorded_at);
    el('humidity-meta').textContent = latest.sample_count + ' sample' + (latest.sample_count === 1 ? '' : 's') + ' averaged';
    statusLabel = 'Updated ' + fmtRelative(latest.recorded_at);
    renderCountdown();

    el('footer-count').textContent = payload.count + ' readings in window';
    el('footer-generated').textContent = 'Exported ' + fmtTime(payload.generated_at);

    drawChart();
    drawTable();
    updateTempTrend(latest.temperature_c);
    updateStats();
  }

  function updateStats() {
    const data = filteredReadings();
    if (!data.length) return;
    const temps = data.map(r => r.temperature_c);
    const hums = data.map(r => r.humidity_pct);
    const avg = (arr) => arr.reduce((a, b) => a + b, 0) / arr.length;

    el('stat-temp-max').textContent = Math.max(...temps).toFixed(1);
    el('stat-temp-min').textContent = Math.min(...temps).toFixed(1);
    el('stat-temp-avg').textContent = avg(temps).toFixed(1);
    el('stat-hum-max').textContent = Math.max(...hums).toFixed(1);
    el('stat-hum-min').textContent = Math.min(...hums).toFixed(1);
    el('stat-hum-avg').textContent = avg(hums).toFixed(1);
  }

  // Compares the last few readings to gauge whether temperature is trending
  // up, down, or flat. Drives both the favicon and the hero trend badge.
  const TREND_SAMPLE_COUNT = 5;
  const TREND_FLAT_THRESHOLD_C = 0.2;

  function getTempTrend() {
    const data = filteredReadings();
    const n = Math.min(TREND_SAMPLE_COUNT, data.length);
    if (n < 2) return null;
    const recent = data.slice(-n);
    const diff = recent[recent.length - 1].temperature_c - recent[0].temperature_c;
    let direction = 'flat';
    if (diff > TREND_FLAT_THRESHOLD_C) direction = 'up';
    else if (diff < -TREND_FLAT_THRESHOLD_C) direction = 'down';
    return { direction, diff };
  }

  // Favicon recolors itself at the extremes so the browser tab gives an
  // at-a-glance read without the dashboard needing to be open.
  const FAVICON_HOT_THRESHOLD_C = 25;
  const FAVICON_COLD_THRESHOLD_C = 20;
  const FAVICON_HOT_COLOR = '#e54848';
  const FAVICON_COLD_COLOR = '#4c8df6';
  const faviconTintCache = new Map();

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

  function updateTempTrend(currentTemp) {
    const trend = getTempTrend();
    const icons = { up: 'thermometer-up-48.png', down: 'thermometer-down-48.png', flat: 'thermometer-48.png' };
    const arrows = { up: '▲', down: '▼', flat: '▬' };
    const direction = trend ? trend.direction : 'flat';

    setFaviconTinted('icon/' + icons[direction], tempIconColor(currentTemp));

    const badge = el('temp-trend');
    badge.classList.remove('trend-up', 'trend-down', 'trend-flat');
    badge.classList.add('trend-' + direction);
    badge.textContent = trend ? `${arrows[direction]} ${Math.abs(trend.diff).toFixed(1)}°` : '';
  }

  function filteredReadings() {
    // Server already returns only the requested window (see loadData),
    // so no client-side re-filtering needed - just hand back what we have.
    return allReadings;
  }

  function drawTable() {
    const recent = filteredReadings().slice(-30).reverse();
    const body = el('log-body');
    body.innerHTML = recent.map(r => `
      <tr>
        <td>${fmtTime(r.recorded_at)}</td>
        <td class="temp-cell">${r.temperature_c.toFixed(1)}</td>
        <td class="humidity-cell">${r.humidity_pct.toFixed(1)}</td>
        <td>${r.sample_count}</td>
      </tr>
    `).join('');
  }

  function drawChart() {
    const data = filteredReadings();
    const svg = el('chart');
    svg.innerHTML = '';

    if (data.length < 2) {
      svg.innerHTML = '<text x="520" y="200" text-anchor="middle" font-size="13">Not enough data points yet</text>';
      return;
    }

    const W = 1040, H = 400;
    const marginLeft = 44, marginRight = 44, marginTop = 16, marginBottom = 32;
    const plotW = W - marginLeft - marginRight;
    const plotH = H - marginTop - marginBottom;

    const times = data.map(r => new Date(r.recorded_at).getTime());
    const temps = data.map(r => r.temperature_c);
    const hums = data.map(r => r.humidity_pct);

    const tMin = Math.min(...times), tMax = Math.max(...times);
    const tempMin = Math.floor(Math.min(...temps) - 1);
    const tempMax = Math.ceil(Math.max(...temps) + 1);
    const humMin = Math.max(0, Math.floor(Math.min(...hums) - 5));
    const humMax = Math.min(100, Math.ceil(Math.max(...hums) + 5));

    const x = (t) => marginLeft + ((t - tMin) / (tMax - tMin || 1)) * plotW;
    const yTemp = (v) => marginTop + plotH - ((v - tempMin) / (tempMax - tempMin || 1)) * plotH;
    const yHum = (v) => marginTop + plotH - ((v - humMin) / (humMax - humMin || 1)) * plotH;

    const ns = 'http://www.w3.org/2000/svg';
    const makeEl = (tag, attrs) => {
      const e = document.createElementNS(ns, tag);
      for (const k in attrs) e.setAttribute(k, attrs[k]);
      return e;
    };

    // Colors are read from CSS variables (not hardcoded) so the chart
    // repaints correctly when the light/dark theme is switched.
    const lineColor = cssVar('--line');
    const lineStrongColor = cssVar('--line-strong');
    const tempColor = cssVar('--temp');
    const humidityColor = cssVar('--humidity');

    // Horizontal gridlines - one thin, slightly transparent line per degree C
    for (let v = Math.ceil(tempMin); v <= Math.floor(tempMax); v++) {
      svg.appendChild(makeEl('line', {
        x1: marginLeft, x2: W - marginRight, y1: yTemp(v), y2: yTemp(v),
        stroke: lineStrongColor, 'stroke-width': 0.5, 'stroke-opacity': 0.35
      }));
    }

    // Vertical gridlines + labels at full-hour marks. Below a day, labels
    // are just "HH" (no minutes - readings always land on the hour), so
    // ticks pack much tighter than full date labels; pick the densest step
    // that still fits without crowding for whichever label format applies.
    const rangeHours = (tMax - tMin) / 3_600_000;
    const HOUR_STEPS = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168, 336, 720, 1440, 2160, 4320, 8760];
    let stepHours = HOUR_STEPS[HOUR_STEPS.length - 1];
    for (const step of HOUR_STEPS) {
      const labelWidthPx = step >= 24 ? 54 : 14;
      const maxTicks = Math.max(2, Math.floor(plotW / labelWidthPx));
      if (rangeHours / step <= maxTicks) { stepHours = step; break; }
    }

    const tick = new Date(tMin);
    tick.setMinutes(0, 0, 0);
    if (tick.getTime() < tMin) tick.setHours(tick.getHours() + 1);

    for (; tick.getTime() <= tMax; tick.setHours(tick.getHours() + stepHours)) {
      const xPos = x(tick.getTime());
      // Quarter-day marks (00/06/12/18) stay near full strength; the rest
      // fade back so an hourly grid doesn't turn into visual noise.
      const isQuarterMark = stepHours < 24 && tick.getHours() % 6 === 0;
      svg.appendChild(makeEl('line', {
        x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom,
        stroke: isQuarterMark ? lineStrongColor : lineColor,
        'stroke-width': 1,
        'stroke-opacity': isQuarterMark ? 0.85 : 0.35
      }));
      const isMidnight = tick.getHours() === 0;
      const label = (stepHours >= 24 || isMidnight)
        ? tick.toLocaleString(undefined, { month: 'short', day: 'numeric' })
        : String(tick.getHours()).padStart(2, '0');
      const textAttrs = { x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': '10' };
      if (isMidnight) textAttrs.transform = `rotate(-45 ${xPos} ${H - 8})`;
      svg.appendChild(makeEl('text', textAttrs)).textContent = label;
    }

    // Sunrise/sunset markers - dashed verticals from the Open-Meteo data
    // readings.php caches and merges into the payload as sun_times[date].
    // Only label them when there are few enough to stay legible (dense
    // long-range views like "ALL" just get the bare dashed lines).
    const sunColor = cssVar('--sun');
    const sunEvents = [];
    for (const day in sunTimes) {
      const { sunrise, sunset } = sunTimes[day];
      if (sunrise) sunEvents.push({ type: 'sunrise', t: new Date(sunrise).getTime() });
      if (sunset) sunEvents.push({ type: 'sunset', t: new Date(sunset).getTime() });
    }
    const visibleSunEvents = sunEvents.filter(e => e.t >= tMin && e.t <= tMax);
    const showSunLabels = visibleSunEvents.length <= 14;
    for (const evt of visibleSunEvents) {
      const xPos = x(evt.t);
      svg.appendChild(makeEl('line', {
        x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom,
        stroke: sunColor, 'stroke-width': 1, 'stroke-dasharray': '3,3', 'stroke-opacity': 0.7
      }));
      if (showSunLabels) {
        svg.appendChild(makeEl('text', {
          x: xPos, y: marginTop + 10, 'text-anchor': 'middle', 'font-size': '10', fill: sunColor
        })).textContent = evt.type === 'sunrise' ? '☀↑' : '☀↓';
      }
    }

    // Y-axis labels - temperature (right, one per whole degree alongside its gridlines)
    for (let v = Math.ceil(tempMin); v <= Math.floor(tempMax); v++) {
      const t = makeEl('text', { x: W - marginRight + 8, y: yTemp(v) + 4, 'text-anchor': 'start', 'font-size': '10', fill: tempColor });
      t.textContent = v.toFixed(0) + '°';
      svg.appendChild(t);
    }

    // Y-axis labels - humidity (left)
    for (let i = 0; i <= 4; i++) {
      const v = humMin + ((humMax - humMin) / 4) * (4 - i);
      const y = marginTop + (plotH / 4) * i;
      const t = makeEl('text', { x: marginLeft - 8, y: y + 4, 'text-anchor': 'end', 'font-size': '10', fill: humidityColor });
      t.textContent = v.toFixed(0) + '%';
      svg.appendChild(t);
    }

    // Build path strings
    const tempPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yTemp(r.temperature_c).toFixed(1)).join(' ');
    const humPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yHum(r.humidity_pct).toFixed(1)).join(' ');

    // Filled area under each line, closed down to the plot baseline
    const baselineY = H - marginBottom;
    const tempAreaPath = `${tempPath} L${x(times[data.length - 1]).toFixed(1)},${baselineY} L${x(times[0]).toFixed(1)},${baselineY} Z`;
    const humAreaPath = `${humPath} L${x(times[data.length - 1]).toFixed(1)},${baselineY} L${x(times[0]).toFixed(1)},${baselineY} Z`;

    svg.appendChild(makeEl('path', { d: humAreaPath, fill: humidityColor, stroke: 'none', 'fill-opacity': 0.08 }));
    svg.appendChild(makeEl('path', { d: tempAreaPath, fill: tempColor, stroke: 'none', 'fill-opacity': 0.08 }));

    svg.appendChild(makeEl('path', { d: humPath, fill: 'none', stroke: humidityColor, 'stroke-width': 1.5, 'stroke-opacity': 0.85 }));
    svg.appendChild(makeEl('path', { d: tempPath, fill: 'none', stroke: tempColor, 'stroke-width': 1.75 }));

    // Latest point markers
    const lastIdx = data.length - 1;
    svg.appendChild(makeEl('circle', { cx: x(times[lastIdx]), cy: yTemp(temps[lastIdx]), r: 3, fill: tempColor }));
    svg.appendChild(makeEl('circle', { cx: x(times[lastIdx]), cy: yHum(hums[lastIdx]), r: 3, fill: humidityColor }));
  }

  // Range button handling - refetches from the server with the new window,
  // since the PHP endpoint only returns the requested hours of history.
  document.getElementById('range-buttons').addEventListener('click', (e) => {
    const btn = e.target.closest('.range-btn');
    if (!btn) return;
    document.querySelectorAll('.range-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    currentRangeHours = parseInt(btn.dataset.hours, 10);
    loadData();
  });

  // Theme toggle - persists the choice and repaints the chart so its
  // CSS-variable-derived colors match the newly selected theme.
  const themeSwitch = el('theme-switch');
  themeSwitch.checked = document.documentElement.getAttribute('data-theme') === 'light';
  themeSwitch.addEventListener('change', () => {
    const theme = themeSwitch.checked ? 'light' : 'dark';
    if (theme === 'light') {
      document.documentElement.setAttribute('data-theme', 'light');
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    localStorage.setItem('theme', theme);
    if (allReadings.length) drawChart();
  });

  loadData();
  setInterval(loadData, REFRESH_MS);
  setInterval(renderCountdown, 1000);
})();
