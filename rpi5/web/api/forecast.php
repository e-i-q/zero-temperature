<?php
/**
 * forecast.php — weather forecast from Open-Meteo, for the Hive
 * dashboard's Forecast tab. Same shape and caching approach as
 * rpi-zero/web/weather.php, but looks forward instead of back: that
 * endpoint clips Open-Meteo's response to [now-delta, now] so no
 * forward-looking data leaks into a historical comparison chart; this one
 * clips to [now, now+delta] so no past data leaks into a forecast.
 *
 * No database involved (unlike readings.php/daily.php) — this is a plain
 * proxy/cache in front of Open-Meteo, same as weather.php. Per-profile
 * *place* persistence (saving named locations, picking which one is
 * active) lives entirely in api/settings.php's `forecast_places` support —
 * this endpoint just plots whatever coordinates it's handed, unaware of
 * profiles or the database that stores them.
 *
 * Query params (all optional):
 *   ?range=24h   A <number><unit> token (unit one of h/d/w/m — hours, days,
 *                weeks, months) or "all". Default 24h. Same shape as
 *                api/readings.php's ?range so the Forecast tab can reuse the
 *                Overview tab's range-chip UI (both driven by the same
 *                user-editable list — see web/api/settings.php). Open-Meteo's
 *                free forecast API only looks FORECAST_DAYS_MAX days ahead,
 *                so anything past that (including "all") is clamped to that
 *                ceiling rather than its literal meaning.
 *   ?lat=49.19   Forecast location, WGS84 decimal degrees. Both or neither —
 *   ?lon=16.61   defaults to DEFAULT_LATITUDE/DEFAULT_LONGITUDE (Brno, the
 *                dashboard's original hardcoded location) when omitted,
 *                which is what a logged-out visitor (or a profile with no
 *                saved forecast_places rows — see settings.php) gets. The
 *                Forecast tab calls this once per saved place, passing
 *                each one's own coordinates, and draws one chart per call.
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const DEFAULT_LATITUDE = 49.1951;  // Brno — same location as rpi-zero/web/weather.php, and this
const DEFAULT_LONGITUDE = 16.6068; // dashboard's only location before per-profile places existed
const FORECAST_DAYS_MAX = 16;      // Open-Meteo's free-tier ceiling for /v1/forecast
const FORECAST_CACHE_TTL = 1800;   // 30 minutes, same as weather.php — forecasts don't move minute to minute
const DEFAULT_RANGE = '24h';

// Turns a "<number><unit>" token into a forward-looking hour count. Returns
// null for anything that isn't a valid token (including "all", which the
// caller handles separately since it has no fixed hour count).
function rangeHours(string $range): ?int {
    if (!preg_match('/^([1-9]\d{0,2})(h|d|w|m)$/', $range, $m)) {
        return null;
    }
    $hoursPerUnit = ['h' => 1, 'd' => 24, 'w' => 24 * 7, 'm' => 24 * 30];
    return (int) $m[1] * $hoursPerUnit[$m[2]];
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

// One cache file per location (rounded to ~11m precision — plenty for a
// weather forecast, and keeps two profiles that both add "Brno" sharing one
// cached fetch instead of duplicating it) so different profiles' places
// don't clobber or evict each other's 30-minute cache the way a single
// fixed-path file would.
function forecastCachePath(float $lat, float $lon): string {
    return sys_get_temp_dir() . '/dht22_forecast_cache_' . sprintf('%.4f_%.4f', $lat, $lon) . '.json';
}

function fetchForecastFromApi(float $lat, float $lon): ?array {
    // Hourly resolution is plenty for a forward-looking chart (unlike
    // weather.php's minutely_15, which exists to compare closely against
    // DHT22 readings taken every few minutes) and keeps FORECAST_DAYS_MAX
    // days of data small: 16 * 24 = 384 points.
    $url = 'https://api.open-meteo.com/v1/forecast?' . http_build_query([
        'latitude'      => $lat,
        'longitude'     => $lon,
        'hourly'        => 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code,rain,snowfall',
        'timezone'      => 'UTC', // keep instants comparable to recorded_at, which is UTC
        'forecast_days' => FORECAST_DAYS_MAX,
    ]);

    // file_get_contents + stream context instead of curl, same as weather.php
    // (setup_nginx_php.sh doesn't install php-curl).
    $context = stream_context_create(['http' => ['timeout' => 5]]);
    $body = @file_get_contents($url, false, $context);
    if ($body === false) return null;

    $data = json_decode($body, true);
    $times = $data['hourly']['time'] ?? null;
    $temps = $data['hourly']['temperature_2m'] ?? null;
    $hums  = $data['hourly']['relative_humidity_2m'] ?? null;
    $winds = $data['hourly']['wind_speed_10m'] ?? null;
    $codes = $data['hourly']['weather_code'] ?? null;
    $rains = $data['hourly']['rain'] ?? null;      // mm, liquid + showers (excludes snowfall)
    $snows = $data['hourly']['snowfall'] ?? null;  // cm
    if (!$times || !$temps || !$hums || !$winds || !$codes || !$rains || !$snows) return null;

    $rows = [];
    foreach ($times as $i => $time) {
        if ($temps[$i] === null || $hums[$i] === null || $winds[$i] === null || $codes[$i] === null
            || $rains[$i] === null || $snows[$i] === null) {
            continue; // skip intervals with incomplete data rather than plotting gaps
        }
        $rows[] = [
            'recorded_at'    => $time . 'Z', // Open-Meteo returns "YYYY-MM-DDTHH:MM" with timezone=UTC
            'temperature_c'  => round((float) $temps[$i], 2),
            'humidity_pct'   => round((float) $hums[$i], 2),
            'wind_speed_kmh' => round((float) $winds[$i], 2),
            'weather_code'   => (int) $codes[$i], // WMO code, used client-side to pick a condition icon
            'rain_mm'        => round((float) $rains[$i], 2),   // this hour's rainfall
            'snowfall_cm'    => round((float) $snows[$i], 2),   // this hour's snowfall
        ];
    }
    return $rows;
}

function getForecastRows(float $lat, float $lon): array {
    $cachePath = forecastCachePath($lat, $lon);
    $cacheFresh = is_file($cachePath) && (time() - filemtime($cachePath)) < FORECAST_CACHE_TTL;

    if (!$cacheFresh) {
        $fetched = fetchForecastFromApi($lat, $lon);
        if ($fetched !== null) {
            file_put_contents($cachePath, json_encode($fetched));
            return $fetched;
        }
        // API unreachable - fall through to whatever is cached, even if stale.
    }

    if (is_file($cachePath)) {
        $cached = json_decode((string) file_get_contents($cachePath), true);
        if (is_array($cached)) return $cached;
    }
    return [];
}

// -- Parse + validate query params ---------------------------------------
$range = (string) ($_GET['range'] ?? DEFAULT_RANGE);
$rawHoursAhead = $range === 'all' ? (FORECAST_DAYS_MAX * 24) : rangeHours($range);
if ($rawHoursAhead === null) {
    $range = DEFAULT_RANGE;
    $rawHoursAhead = rangeHours(DEFAULT_RANGE);
}
// Open-Meteo's free tier never has more than FORECAST_DAYS_MAX days cached
// regardless of what's requested — clamp explicitly (rather than relying on
// the array_filter below to just come up short) so the client can be told
// this window was cut short instead of silently getting fewer rows than a
// literal reading of its own chip would suggest.
$hoursAhead = min($rawHoursAhead, FORECAST_DAYS_MAX * 24);
$clamped = $rawHoursAhead > FORECAST_DAYS_MAX * 24;

// `lat`/`lon` are either both present (a profile's active place, or one
// being tried out ahead of saving it) or both absent (Brno) — one without
// the other is almost certainly a caller bug, so it fails loudly rather
// than silently mixing a given lat with the default lon.
$latParam = $_GET['lat'] ?? null;
$lonParam = $_GET['lon'] ?? null;
if (($latParam === null) !== ($lonParam === null)) {
    fail(400, 'lat and lon must be given together.');
}
if ($latParam !== null) {
    if (!is_numeric($latParam) || !is_numeric($lonParam)) {
        fail(400, 'lat/lon must be numbers.');
    }
    $latitude = (float) $latParam;
    $longitude = (float) $lonParam;
    if ($latitude < -90 || $latitude > 90 || $longitude < -180 || $longitude > 180) {
        fail(400, 'lat must be in [-90, 90] and lon in [-180, 180].');
    }
} else {
    $latitude = DEFAULT_LATITUDE;
    $longitude = DEFAULT_LONGITUDE;
}

$all = getForecastRows($latitude, $longitude);

// Forward-looking view, mirror image of weather.php's backward clip: keep
// [now, now+hoursAhead] so nothing from the past sneaks in and the horizon
// never exceeds what was actually requested.
$nowTs = time();
$cutoffTs = $nowTs + $hoursAhead * 3600;
$readings = array_values(array_filter($all, function ($r) use ($cutoffTs, $nowTs) {
    $ts = strtotime($r['recorded_at']);
    return $ts !== false && $ts >= $nowTs && $ts <= $cutoffTs;
}));

$soonest = !empty($readings) ? $readings[0] : null;

$payload = [
    'generated_at'      => gmdate('c'),
    'range'             => $range,
    'latitude'          => $latitude,  // echoed back so the client can confirm which place this actually plotted
    'longitude'         => $longitude,
    'forecast_days_max' => FORECAST_DAYS_MAX,
    'clamped'           => $clamped, // true if $range asked for more than Open-Meteo can give
    'count'             => count($readings),
    'latest'            => $soonest, // nearest upcoming hour, not "most recent" — there's no history here
    'readings'          => $readings,
];

echo json_encode($payload, JSON_UNESCAPED_SLASHES);
