<?php
/**
 * weather.php — Historical Brno weather from Open-Meteo, for comparison
 * against the DHT22 sensor readings (not a forecast: future hours are
 * dropped, only the past is returned).
 *
 * Query params (all optional):
 *   ?hours=24    How many hours of history to return (default 48)
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const WEATHER_LATITUDE = 49.1951;  // Brno
const WEATHER_LONGITUDE = 16.6068;
const DEFAULT_HOURS = 48;

// Open-Meteo's hourly archive only covers a rolling window (max 92 past +
// a couple of forecast days), same constraint as the sunrise/sunset call
// in readings.php. Cached for 30 minutes since hourly weather doesn't move
// fast enough to justify hitting the API on every dashboard poll.
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
    $url = 'https://api.open-meteo.com/v1/forecast?' . http_build_query([
        'latitude'      => WEATHER_LATITUDE,
        'longitude'     => WEATHER_LONGITUDE,
        'hourly'        => 'temperature_2m,relative_humidity_2m,wind_speed_10m,cloud_cover',
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
    $times  = $data['hourly']['time'] ?? null;
    $temps  = $data['hourly']['temperature_2m'] ?? null;
    $hums   = $data['hourly']['relative_humidity_2m'] ?? null;
    $winds  = $data['hourly']['wind_speed_10m'] ?? null;
    $clouds = $data['hourly']['cloud_cover'] ?? null;
    if (!$times || !$temps || !$hums || !$winds || !$clouds) return null;

    $rows = [];
    foreach ($times as $i => $time) {
        if ($temps[$i] === null || $hums[$i] === null || $winds[$i] === null || $clouds[$i] === null) {
            continue; // skip hours with incomplete data rather than plotting gaps
        }
        $rows[] = [
            'recorded_at'    => $time . 'Z', // Open-Meteo returns "YYYY-MM-DDTHH:MM" with timezone=UTC
            'temperature_c'  => round((float) $temps[$i], 2),
            'humidity_pct'   => round((float) $hums[$i], 2),
            'wind_speed_kmh' => round((float) $winds[$i], 2),
            'cloud_pct'      => (int) $clouds[$i],
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
$hours = isset($_GET['hours']) ? (int) $_GET['hours'] : DEFAULT_HOURS;
if ($hours < 1 || $hours > 8760) {
    $hours = DEFAULT_HOURS;
}

$all = getWeatherRows();

// This is a comparison view, not a forecast - clip to [now-hours, now] so
// no forward-looking data sneaks in from the API's forecast_days=1 buffer.
$nowTs = time();
$cutoffTs = $nowTs - $hours * 3600;
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
