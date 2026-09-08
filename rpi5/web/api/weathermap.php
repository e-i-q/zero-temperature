<?php
/**
 * weathermap.php — OpenWeatherMap-backed data for the Forecast tab's
 * weather map (clouds/rain/wind tile overlays + thunderstorm markers),
 * centered on the Czech Republic. Same "plain proxy" shape as
 * forecast.php/geocode.php, but talks to OpenWeatherMap instead of
 * Open-Meteo — Open-Meteo has no tile-map product of its own.
 *
 * The API key lives OUTSIDE this repo, same convention as
 * api/sync_trigger.php's X-Sync-Token: provisioned by
 * setup/setup_weathermap.sh into OWM_APIKEY_FILE below (root:www-data,
 * 640), never committed to git (see ../../../.gitignore) and never shipped
 * inside web/, which is all that setup/deploy_web.sh copies into the
 * nginx web root.
 *
 * Query params:
 *   ?action=tiles    Returns {"appid": "<key>"} so the client can build OWM
 *                    tile URLs itself
 *                    (https://tile.openweathermap.org/map/{layer}/{z}/{x}/{y}.png?appid=...).
 *                    Raster tiles have to be fetched straight from the
 *                    browser — proxying every one through this Pi would be
 *                    slow and pointless — so the key is visible in those
 *                    tile requests either way; returning it here too costs
 *                    nothing extra.
 *   ?action=thunder  Returns current thunderstorm points across the Czech
 *                    Republic (see THUNDER_POINTS below), cached
 *                    THUNDER_CACHE_TTL like forecast.php caches Open-Meteo.
 *                    OpenWeatherMap's free Weather Maps 1.0 tier ships
 *                    exactly five raster tile layers (clouds_new,
 *                    precipitation_new, pressure_new, wind_new, temp_new)
 *                    — there is no dedicated thunderstorm tile at any tier
 *                    — so instead this samples current conditions (OWM
 *                    weather-condition id 2xx = thunderstorm group) at a
 *                    fixed spread of towns and reports which ones are
 *                    seeing one right now.
 */

declare(strict_types=1);

const OWM_APIKEY_FILE = '/etc/dht22-weathermap/apikey';
const THUNDER_CACHE_TTL = 1800;     // 30 minutes, same cadence as forecast.php
const THUNDER_REQUEST_TIMEOUT = 4;  // seconds, per point below

// A geographic spread across the Czech Republic, not an exhaustive city
// list — enough points that a thunderstorm anywhere in the country shows
// up somewhere on the map, without firing off dozens of upstream calls
// every time the cache goes stale.
const THUNDER_POINTS = [
    ['name' => 'Prague',           'lat' => 50.0755, 'lon' => 14.4378],
    ['name' => 'Brno',             'lat' => 49.1951, 'lon' => 16.6068],
    ['name' => 'Ostrava',          'lat' => 49.8209, 'lon' => 18.2625],
    ['name' => 'Plzeň',            'lat' => 49.7384, 'lon' => 13.3736],
    ['name' => 'Liberec',          'lat' => 50.7663, 'lon' => 15.0543],
    ['name' => 'Olomouc',          'lat' => 49.5938, 'lon' => 17.2509],
    ['name' => 'České Budějovice', 'lat' => 48.9744, 'lon' => 14.4747],
    ['name' => 'Hradec Králové',   'lat' => 50.2092, 'lon' => 15.8328],
];

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

function apiKey(): string {
    if (!is_file(OWM_APIKEY_FILE)) {
        fail(500, 'Weather map is not configured on the Hive — run rpi5/setup/setup_weathermap.sh.');
    }
    $key = trim((string) file_get_contents(OWM_APIKEY_FILE));
    if ($key === '') {
        fail(500, 'Weather map API key file is empty — re-run rpi5/setup/setup_weathermap.sh.');
    }
    return $key;
}

// One cache file for the whole country (unlike forecast.php's per-location
// cache) — there's only ever one THUNDER_POINTS sweep to remember.
function thunderCachePath(): string {
    return sys_get_temp_dir() . '/dht22_weathermap_thunder_cache.json';
}

// One current-conditions lookup per THUNDER_POINTS entry, kept independent
// so one slow/unreachable point doesn't blank out the rest — same
// skip-what's-incomplete spirit as forecast.php's row filtering. Returns
// null (not an empty array) if OWM couldn't be reached for ANY point, so
// the caller can tell "totally unreachable" apart from "reachable, nothing
// stormy right now" and fall back to a stale cache only for the former.
function fetchThunderPoints(string $key): ?array {
    $context = stream_context_create(['http' => ['timeout' => THUNDER_REQUEST_TIMEOUT]]);
    $checked = 0;
    $active = [];
    foreach (THUNDER_POINTS as $point) {
        $url = 'https://api.openweathermap.org/data/2.5/weather?' . http_build_query([
            'lat'   => $point['lat'],
            'lon'   => $point['lon'],
            'appid' => $key,
        ]);
        $body = @file_get_contents($url, false, $context);
        if ($body === false) continue;
        $checked++;

        $data = json_decode($body, true);
        $weather = $data['weather'][0] ?? null;
        $id = $weather['id'] ?? null;
        if (!is_numeric($id) || (int) $id < 200 || (int) $id >= 300) continue; // 2xx = thunderstorm group

        $active[] = [
            'name'        => $point['name'],
            'latitude'    => $point['lat'],
            'longitude'   => $point['lon'],
            'description' => $weather['description'] ?? 'thunderstorm',
        ];
    }
    return $checked > 0 ? $active : null;
}

function getThunderPoints(string $key): array {
    $cachePath = thunderCachePath();
    $cacheFresh = is_file($cachePath) && (time() - filemtime($cachePath)) < THUNDER_CACHE_TTL;

    if (!$cacheFresh) {
        set_time_limit(60); // up to 8 sequential upstream calls above — generous but bounded, same idea as sync_trigger.php's REQUEST_TIMEOUT_SECONDS
        $fetched = fetchThunderPoints($key);
        if ($fetched !== null) {
            file_put_contents($cachePath, json_encode($fetched));
            return $fetched;
        }
        // OWM unreachable for every point - fall through to whatever is cached, even if stale.
    }

    if (is_file($cachePath)) {
        $cached = json_decode((string) file_get_contents($cachePath), true);
        if (is_array($cached)) return $cached;
    }
    return [];
}

$action = (string) ($_GET['action'] ?? '');
$key = apiKey();

if ($action === 'tiles') {
    echo json_encode(['appid' => $key]);
} elseif ($action === 'thunder') {
    echo json_encode([
        'generated_at' => gmdate('c'),
        'points'       => getThunderPoints($key),
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
} else {
    fail(400, 'action must be "tiles" or "thunder".');
}
