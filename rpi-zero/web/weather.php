<?php
/**
 * weather.php — Historical Brno weather from Open-Meteo, for comparison
 * against the DHT22 sensor readings (not a forecast: future hours are
 * dropped, only the past is returned).
 *
 * Query params (all optional):
 *   ?delta=-24 hours  SQLite-style datetime() modifier for how far back to
 *                     go (default -48 hours). Same contract as readings.php's
 *                     ?delta so both charts can share one range selector;
 *                     anything not matching DELTA_PATTERN falls back to the default.
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const WEATHER_LATITUDE = 49.1951;  // Brno
const WEATHER_LONGITUDE = 16.6068;
const DEFAULT_DELTA = '-48 hours';
const DELTA_PATTERN = '/^-([1-9][0-9]{0,5}) (minutes|hours|days)$/';

// past_days=92 is requested below, same as the sunrise/sunset call in
// readings.php, but Open-Meteo's minutely_15 model data doesn't necessarily
// keep a full 92 days of history at that resolution - long ranges (7D/ALL)
// may come back sparser than the hourly archive would provide. Cached for
// 30 minutes so a busy dashboard isn't re-fetching this every poll.
const WEATHER_CACHE_TTL = 1800;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

function weatherCachePath(): string {
    return sys_get_temp_dir() . '/dht22_weather_cache.json';
}

function fetchWeatherFromApi(): ?array {
    // minutely_15 instead of hourly - the finest real granularity Open-Meteo
    // offers (there's no native 10-minute resolution). It doesn't carry
    // cloud_cover, so weather_code (a WMO code) drives icon selection instead.
    $url = 'https://api.open-meteo.com/v1/forecast?' . http_build_query([
        'latitude'      => WEATHER_LATITUDE,
        'longitude'     => WEATHER_LONGITUDE,
        'minutely_15'   => 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
        'timezone'      => 'UTC', // keep instants comparable to recorded_at, which is UTC
        'past_days'     => 92,
        'forecast_days' => 1,
    ]);

    // file_get_contents + stream context instead of curl, same as readings.php
    // (setup_nginx_php.sh doesn't install php-curl).
    $context = stream_context_create(['http' => ['timeout' => 5]]);
    $body = @file_get_contents($url, false, $context);
    if ($body === false) return null;

    $data = json_decode($body, true);
    $times = $data['minutely_15']['time'] ?? null;
    $temps = $data['minutely_15']['temperature_2m'] ?? null;
    $hums  = $data['minutely_15']['relative_humidity_2m'] ?? null;
    $winds = $data['minutely_15']['wind_speed_10m'] ?? null;
    $codes = $data['minutely_15']['weather_code'] ?? null;
    if (!$times || !$temps || !$hums || !$winds || !$codes) return null;

    $rows = [];
    foreach ($times as $i => $time) {
        if ($temps[$i] === null || $hums[$i] === null || $winds[$i] === null || $codes[$i] === null) {
            continue; // skip intervals with incomplete data rather than plotting gaps
        }
        $rows[] = [
            'recorded_at'   => $time . 'Z', // Open-Meteo returns "YYYY-MM-DDTHH:MM" with timezone=UTC
            'temperature_c' => round((float) $temps[$i], 2),
            'humidity_pct'  => round((float) $hums[$i], 2),
            'wind_speed_kmh' => round((float) $winds[$i], 2),
            'weather_code'  => (int) $codes[$i], // WMO code, used client-side to pick a condition icon
        ];
    }
    return $rows;
}

function getWeatherRows(): array {
    $cachePath = weatherCachePath();
    $cacheFresh = is_file($cachePath) && (time() - filemtime($cachePath)) < WEATHER_CACHE_TTL;

    if (!$cacheFresh) {
        $fetched = fetchWeatherFromApi();
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
$delta = isset($_GET['delta']) ? (string) $_GET['delta'] : DEFAULT_DELTA;
if (!preg_match(DELTA_PATTERN, $delta)) {
    $delta = DEFAULT_DELTA;
}

$all = getWeatherRows();

// This is a comparison view, not a forecast - clip to [now+delta, now] so
// no forward-looking data sneaks in from the API's forecast_days=1 buffer.
// PHP's strtotime() understands the same relative-modifier syntax SQLite's
// datetime() does (e.g. "-24 hours", "-7 days"), so $delta needs no parsing.
$nowTs = time();
$cutoffTs = strtotime($delta, $nowTs);
$readings = array_values(array_filter($all, function ($r) use ($cutoffTs, $nowTs) {
    $ts = strtotime($r['recorded_at']);
    return $ts !== false && $ts >= $cutoffTs && $ts <= $nowTs;
}));

$latest = !empty($readings) ? end($readings) : null;

$payload = [
    'generated_at' => gmdate('c'),
    'count'        => count($readings),
    'latest'       => $latest,
    'readings'     => $readings,
];

echo json_encode($payload, JSON_UNESCAPED_SLASHES);
