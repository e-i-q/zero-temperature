<?php
/**
 * readings.php � Live SQLite ? JSON endpoint for the DHT22 dashboard.
 *
 * Replaces the cron + export_readings_json.py approach: this queries the
 * SQLite database directly on every request, so the dashboard always shows
 * current data with no export delay.
 *
 * Query params (all optional):
 *   ?delta=-24 hours  SQLite datetime() modifier for how far back to query
 *                     (default -48 hours). Must match DELTA_PATTERN below;
 *                     anything else falls back to the default.
 *   ?limit=2000       Max rows to return (default 2000)
 *
 * Configure DB_PATH below to point at your RAM-disk database.
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const DB_PATH = '/mnt/sqlite_ram/sensors.db';
const DEFAULT_DELTA = '-48 hours';
const DELTA_PATTERN = '/^-([1-9][0-9]{0,5}) (minutes|hours|days)$/';
const DEFAULT_LIMIT = 2000;
const MAX_LIMIT = 5000; // dashboard's "ALL" view requests up to -8760 hours (1yr); LIMIT still caps row count returned

// Sunrise/sunset for the chart's day/night markers. Open-Meteo's daily
// sunrise/sunset variable only covers a rolling forecast+history window
// (max 92 past + 16 forecast days), which is plenty for the 6H/24H/48H
// views and covers the recent part of "ALL". Cached for a day since these
// times barely move from one poll to the next.
const SUN_LATITUDE = 49.1951;  // Brno
const SUN_LONGITUDE = 16.6068;
const SUN_CACHE_TTL = 86400;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

// -- Sunrise/sunset (Open-Meteo, file-cached) ------------------------------
function sunCachePath(): string {
    return sys_get_temp_dir() . '/dht22_sun_times_cache.json';
}

function fetchSunTimesFromApi(): ?array {
    $url = 'https://api.open-meteo.com/v1/forecast?' . http_build_query([
        'latitude'      => SUN_LATITUDE,
        'longitude'     => SUN_LONGITUDE,
        'daily'         => 'sunrise,sunset',
        'timezone'      => 'auto',
        'past_days'     => 92,
        'forecast_days' => 16,
    ]);

    // file_get_contents + stream context instead of curl - keeps this free
    // of the php-curl extension, which setup_nginx_php.sh doesn't install.
    $context = stream_context_create(['http' => ['timeout' => 5]]);
    $body = @file_get_contents($url, false, $context);
    if ($body === false) return null;

    $data = json_decode($body, true);
    $days = $data['daily']['time'] ?? null;
    $sunrises = $data['daily']['sunrise'] ?? null;
    $sunsets = $data['daily']['sunset'] ?? null;
    if (!$days || !$sunrises || !$sunsets) return null;

    $sunTimes = [];
    foreach ($days as $i => $date) {
        $sunTimes[$date] = ['sunrise' => $sunrises[$i] ?? null, 'sunset' => $sunsets[$i] ?? null];
    }
    return $sunTimes;
}

function getSunTimes(): array {
    $cachePath = sunCachePath();
    $cacheFresh = is_file($cachePath) && (time() - filemtime($cachePath)) < SUN_CACHE_TTL;

    if (!$cacheFresh) {
        $fetched = fetchSunTimesFromApi();
        if ($fetched !== null) {
            file_put_contents($cachePath, json_encode($fetched));
            return $fetched;
        }
        // API unreachable - fall through to whatever is cached, even if stale,
        // rather than dropping the markers entirely for this request.
    }

    if (is_file($cachePath)) {
        $cached = json_decode((string) file_get_contents($cachePath), true);
        if (is_array($cached)) return $cached;
    }
    return [];
}

// -- Parse + validate query params ---------------------------------------
$delta = isset($_GET['delta']) ? (string) $_GET['delta'] : DEFAULT_DELTA;
$limit = isset($_GET['limit']) ? (int) $_GET['limit'] : DEFAULT_LIMIT;

// $delta is bound as a parameter below (never concatenated into SQL), but it
// still has to be a valid SQLite datetime() modifier - reject anything else
// rather than letting datetime() silently no-op on a malformed string.
if (!preg_match(DELTA_PATTERN, $delta)) {
    $delta = DEFAULT_DELTA;
}
if ($limit < 1 || $limit > MAX_LIMIT) {
    $limit = DEFAULT_LIMIT;
}

// -- Connect --------------------------------------------------------------
if (!file_exists(DB_PATH)) {
    fail(503, 'Database not found at ' . DB_PATH . ' � has the logger run yet?');
}

try {
    // Open read-only via SQLite's URI syntax � PHP never writes to this
    // database. The database itself uses DELETE journal mode (not WAL),
    // so there are no -shm/-wal sidecar files to worry about; a plain
    // read-only open against the .db file is all that's needed.
    $pdo = new PDO('sqlite:file:' . DB_PATH . '?mode=ro', null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $pdo->exec('PRAGMA busy_timeout = 3000');
} catch (PDOException $e) {
    fail(
        500,
        'Could not open database read-only: ' . $e->getMessage() .
        '. Check that ' . DB_PATH . ' exists and is readable by the web server user (www-data).'
    );
}

// -- Query ----------------------------------------------------------------
try {
    $stmt = $pdo->prepare(
        "SELECT recorded_at, sensor, temperature_c, humidity_pct, sample_count
         FROM readings
         WHERE datetime(recorded_at) >= datetime('now', :window)
         ORDER BY recorded_at ASC
         LIMIT :limit"
    );
    $stmt->bindValue(':window', $delta, PDO::PARAM_STR);
    $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
    $stmt->execute();
    $readings = $stmt->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Query failed: ' . $e->getMessage());
}

// Cast numeric fields � SQLite via PDO can return strings for some types
foreach ($readings as &$row) {
    $row['temperature_c'] = round((float) $row['temperature_c'], 2);
    $row['humidity_pct']  = round((float) $row['humidity_pct'], 2);
    $row['sample_count']  = (int) $row['sample_count'];
}
unset($row);

$latest = !empty($readings) ? end($readings) : null;

$payload = [
    'generated_at' => gmdate('c'),
    'count'        => count($readings),
    'latest'       => $latest,
    'readings'     => $readings,
    'sun_times'    => getSunTimes(),
];

echo json_encode($payload, JSON_UNESCAPED_SLASHES);