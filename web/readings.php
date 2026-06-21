<?php
/**
 * readings.php � Live SQLite ? JSON endpoint for the DHT22 dashboard.
 *
 * Replaces the cron + export_readings_json.py approach: this queries the
 * SQLite database directly on every request, so the dashboard always shows
 * current data with no export delay.
 *
 * Query params (all optional):
 *   ?hours=24    How many hours of history to return (default 48)
 *   ?limit=2000  Max rows to return (default 2000)
 *
 * Configure DB_PATH below to point at your RAM-disk database.
 */

declare(strict_types=1);

// -- Configuration --------------------------------------------------------
const DB_PATH = '/mnt/sqlite_ram/sensors.db';
const DEFAULT_HOURS = 48;
const DEFAULT_LIMIT = 2000;
const MAX_LIMIT = 5000; // dashboard's "ALL" view requests up to 8760h (1yr); LIMIT still caps row count returned

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

// -- Parse + validate query params ---------------------------------------
$hours = isset($_GET['hours']) ? (int) $_GET['hours'] : DEFAULT_HOURS;
$limit = isset($_GET['limit']) ? (int) $_GET['limit'] : DEFAULT_LIMIT;

if ($hours < 1 || $hours > 8760) {
    $hours = DEFAULT_HOURS;
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
    $stmt->bindValue(':window', "-{$hours} hours", PDO::PARAM_STR);
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
];

echo json_encode($payload, JSON_UNESCAPED_SLASHES);