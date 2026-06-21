(function () {
  const DATA_URL = 'readings.php';
  const REFRESH_MS = 60000; // poll for new data every minute

  let allReadings = [];
  let currentRangeHours = 24;
  let statusLabel = 'Loading…';
  let nextFetchAt = Date.now() + REFRESH_MS;

  const el = (id) => document.getElementById(id);

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
    el('current-temp').innerHTML = latest.temperature_c.toFixed(1) + '<span class="hero-unit">°C</span>';
    el('current-humidity').innerHTML = latest.humidity_pct.toFixed(1) + '<span class="hero-unit">%</span>';
    el('temp-meta').textContent = fmtTime(latest.recorded_at) + ' — ' + fmtRelative(latest.recorded_at);
    el('humidity-meta').textContent = latest.sample_count + ' sample' + (latest.sample_count === 1 ? '' : 's') + ' averaged';
    statusLabel = 'Updated ' + fmtRelative(latest.recorded_at);
    renderCountdown();

    el('footer-count').textContent = payload.count + ' readings in window';
    el('footer-generated').textContent = 'Exported ' + fmtTime(payload.generated_at);

    drawChart();
    drawTable();
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
      svg.innerHTML = '<text x="440" y="160" text-anchor="middle" font-size="13">Not enough data points yet</text>';
      return;
    }

    const W = 880, H = 320;
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

    // Horizontal gridlines - one thin, slightly transparent line per degree C
    for (let v = Math.ceil(tempMin); v <= Math.floor(tempMax); v++) {
      svg.appendChild(makeEl('line', {
        x1: marginLeft, x2: W - marginRight, y1: yTemp(v), y2: yTemp(v),
        stroke: '#B7AF9D', 'stroke-width': 0.5, 'stroke-opacity': 0.35
      }));
    }

    // Vertical gridlines + labels at full-hour marks. Pick the densest step
    // (from a list of "nice" hour intervals) whose ticks still fit the
    // available width without crowding the labels.
    const rangeHours = (tMax - tMin) / 3_600_000;
    const HOUR_STEPS = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168, 336, 720, 1440, 2160, 4320, 8760];
    const minLabelSpacingPx = 56;
    const maxTicks = Math.max(2, Math.floor(plotW / minLabelSpacingPx));
    let stepHours = HOUR_STEPS[HOUR_STEPS.length - 1];
    for (const step of HOUR_STEPS) {
      if (rangeHours / step <= maxTicks) { stepHours = step; break; }
    }

    const tick = new Date(tMin);
    tick.setMinutes(0, 0, 0);
    if (tick.getTime() < tMin) tick.setHours(tick.getHours() + 1);

    for (; tick.getTime() <= tMax; tick.setHours(tick.getHours() + stepHours)) {
      const xPos = x(tick.getTime());
      svg.appendChild(makeEl('line', {
        x1: xPos, x2: xPos, y1: marginTop, y2: H - marginBottom,
        stroke: '#D8D2C4', 'stroke-width': 1
      }));
      const label = stepHours >= 24
        ? tick.toLocaleString(undefined, { month: 'short', day: 'numeric' })
        : tick.toLocaleString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
      svg.appendChild(makeEl('text', {
        x: xPos, y: H - 8, 'text-anchor': 'middle', 'font-size': '10'
      })).textContent = label;
    }

    // Y-axis labels - temperature (right, one per whole degree alongside its gridlines)
    for (let v = Math.ceil(tempMin); v <= Math.floor(tempMax); v++) {
      const t = makeEl('text', { x: W - marginRight + 8, y: yTemp(v) + 4, 'text-anchor': 'start', 'font-size': '10', fill: '#C1502E' });
      t.textContent = v.toFixed(0) + '°';
      svg.appendChild(t);
    }

    // Y-axis labels - humidity (left)
    for (let i = 0; i <= 4; i++) {
      const v = humMin + ((humMax - humMin) / 4) * (4 - i);
      const y = marginTop + (plotH / 4) * i;
      const t = makeEl('text', { x: marginLeft - 8, y: y + 4, 'text-anchor': 'end', 'font-size': '10', fill: '#3A5A78' });
      t.textContent = v.toFixed(0) + '%';
      svg.appendChild(t);
    }

    // Build path strings
    const tempPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yTemp(r.temperature_c).toFixed(1)).join(' ');
    const humPath = data.map((r, i) => (i === 0 ? 'M' : 'L') + x(times[i]).toFixed(1) + ',' + yHum(r.humidity_pct).toFixed(1)).join(' ');

    svg.appendChild(makeEl('path', { d: humPath, fill: 'none', stroke: '#3A5A78', 'stroke-width': 1.5, 'stroke-opacity': 0.85 }));
    svg.appendChild(makeEl('path', { d: tempPath, fill: 'none', stroke: '#C1502E', 'stroke-width': 1.75 }));

    // Latest point markers
    const lastIdx = data.length - 1;
    svg.appendChild(makeEl('circle', { cx: x(times[lastIdx]), cy: yTemp(temps[lastIdx]), r: 3, fill: '#C1502E' }));
    svg.appendChild(makeEl('circle', { cx: x(times[lastIdx]), cy: yHum(hums[lastIdx]), r: 3, fill: '#3A5A78' }));
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

  loadData();
  setInterval(loadData, REFRESH_MS);
  setInterval(renderCountdown, 1000);
})();
