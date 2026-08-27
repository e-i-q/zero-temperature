<?php
/**
 * forecast.php — Brno weather forecast from Open-Meteo, for the Hive
 * dashboard's Forecast tab. Same shape and caching approach as
 * rpi-zero/web/weather.php, but looks forward instead of back: that
 * endpoint clips Open-Meteo's response to [now-delta, now] so no
 * forward-looking data leaks into a historical comparison chart; this one
 * clips to [now, now+delta] so no past data leaks into a forecast.
 *
 * No database involved (unlike readings.php/daily.php) — this is a plain
 * proxy/cache in front of Open-Meteo, same as weather.php.
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
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const WEATHER_LATITUDE = 49.1951;  // Brno — same location as rpi-zero/web/weather.php
const WEATHER_LONGITUDE = 16.6068;
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

function forecastCachePath(): string {
    return sys_get_temp_dir() . '/dht22_forecast_cache.json';
}

function fetchForecastFromApi(): ?array {
    // Hourly resolution is plenty for a forward-looking chart (unlike
    // weather.php's minutely_15, which exists to compare closely against
    // DHT22 readings taken every few minutes) and keeps FORECAST_DAYS_MAX
    // days of data small: 16 * 24 = 384 points.
    $url = 'https://api.open-meteo.com/v1/forecast?' . http_build_query([
        'latitude'      => WEATHER_LATITUDE,
        'longitude'     => WEATHER_LONGITUDE,
        'hourly'        => 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
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
    if (!$times || !$temps || !$hums || !$winds || !$codes) return null;

    $rows = [];
    foreach ($times as $i => $time) {
        if ($temps[$i] === null || $hums[$i] === null || $winds[$i] === null || $codes[$i] === null) {
            continue; // skip intervals with incomplete data rather than plotting gaps
        }
        $rows[] = [
            'recorded_at'    => $time . 'Z', // Open-Meteo returns "YYYY-MM-DDTHH:MM" with timezone=UTC
            'temperature_c'  => round((float) $temps[$i], 2),
            'humidity_pct'   => round((float) $hums[$i], 2),
            'wind_speed_kmh' => round((float) $winds[$i], 2),
            'weather_code'   => (int) $codes[$i], // WMO code, used client-side to pick a condition icon
        ];
    }
    return $rows;
}

function getForecastRows(): array {
    $cachePath = forecastCachePath();
    $cacheFresh = is_file($cachePath) && (time() - filemtime($cachePath)) < FORECAST_CACHE_TTL;

    if (!$cacheFresh) {
        $fetched = fetchForecastFromApi();
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

$all = getForecastRows();

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
    'forecast_days_max' => FORECAST_DAYS_MAX,
    'clamped'           => $clamped, // true if $range asked for more than Open-Meteo can give
    'count'             => count($readings),
    'latest'            => $soonest, // nearest upcoming hour, not "most recent" — there's no history here
    'readings'          => $readings,
];

echo json_encode($payload, JSON_UNESCAPED_SLASHES);
