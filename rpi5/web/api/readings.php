<?php
/**
 * readings.php — JSON endpoint for the Hive dashboard: every registered
 * sensor's readings within the requested window, queried live from the
 * central PostgreSQL database (no caching — this is the whole point of
 * centralizing the data).
 *
 * Query params (all optional):
 *   ?range=24h   One of RANGE_INTERVALS below, or "all". Default 24h.
 */

declare(strict_types=1);

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

// -- Configuration ----------------------------------------------------------
const RANGE_INTERVALS = [
    '12h' => '12 hours',
    '24h' => '24 hours',
    '2d'  => '2 days',
    '5d'  => '5 days',
    '1m'  => '1 month',
];
const DEFAULT_RANGE = '24h';

// A sensor with no reading in the last OFFLINE_MINUTES is shown as offline.
// Zeros default to a 10-minute cron interval (setup_dht22_logger.sh), so 30
// minutes tolerates a few missed/best-effort remote writes before flagging.
const OFFLINE_MINUTES = 30;

// Safety cap on rows returned for the "all" range on a long-running install
// — the dashboard downsamples nothing server-side, so this bounds payload
// size rather than the (unbounded) time window itself.
const MAX_ROWS = 20000;

// -- Parse + validate query params ------------------------------------------
$range = (string) ($_GET['range'] ?? DEFAULT_RANGE);
if ($range !== 'all' && !array_key_exists($range, RANGE_INTERVALS)) {
    $range = DEFAULT_RANGE;
}

$pdo = db();

// -- Sensor registry — always return every sensor, even ones with zero
// readings in this window, so the dashboard can still render an offline
// tile for them instead of silently dropping them. --------------------------
try {
    $sensors = $pdo->query('SELECT id, name, description FROM sensors ORDER BY name')->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Could not read sensor registry: ' . $e->getMessage());
}

// -- Readings -----------------------------------------------------------------
$sql = 'SELECT sensor_id, recorded_at, temperature_c, humidity_pct, sample_count FROM readings';
if ($range !== 'all') {
    $sql .= ' WHERE recorded_at >= now() - :window::interval';
}
$sql .= ' ORDER BY recorded_at ASC LIMIT :limit';

try {
    $stmt = $pdo->prepare($sql);
    if ($range !== 'all') {
        $stmt->bindValue(':window', RANGE_INTERVALS[$range], PDO::PARAM_STR);
    }
    $stmt->bindValue(':limit', MAX_ROWS, PDO::PARAM_INT);
    $stmt->execute();
    $rows = $stmt->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Query failed: ' . $e->getMessage());
}

// -- Shape into per-sensor series + per-sensor latest/stats -------------------
$series = [];
$latestBySensor = [];
foreach ($sensors as $s) {
    $series[(int) $s['id']] = [];
}

foreach ($rows as $row) {
    $sid = (int) $row['sensor_id'];
    if (!array_key_exists($sid, $series)) {
        continue; // reading references a sensor_id no longer in the registry
    }
    $point = [
        'recorded_at'   => $row['recorded_at'],
        'temperature_c' => round((float) $row['temperature_c'], 2),
        'humidity_pct'  => round((float) $row['humidity_pct'], 2),
        'sample_count'  => (int) $row['sample_count'],
    ];
    $series[$sid][] = $point;
    $latestBySensor[$sid] = $point;
}

$nowTs = time();
$sensorsOut = [];
foreach ($sensors as $s) {
    $sid = (int) $s['id'];
    $pts = $series[$sid];
    $latest = $latestBySensor[$sid] ?? null;
    $lastSeenTs = $latest ? strtotime($latest['recorded_at']) : false;
    $online = $lastSeenTs !== false && ($nowTs - $lastSeenTs) <= OFFLINE_MINUTES * 60;

    $temps = array_column($pts, 'temperature_c');
    $hums  = array_column($pts, 'humidity_pct');

    $sensorsOut[] = [
        'id'          => $sid,
        'name'        => $s['name'],
        'description' => $s['description'],
        'online'      => $online,
        'latest'      => $latest,
        'stats'       => $temps ? [
            'temp_min' => round(min($temps), 1),
            'temp_max' => round(max($temps), 1),
            'temp_avg' => round(array_sum($temps) / count($temps), 1),
            'hum_min'  => round(min($hums), 1),
            'hum_max'  => round(max($hums), 1),
            'hum_avg'  => round(array_sum($hums) / count($hums), 1),
        ] : null,
    ];
}

echo json_encode([
    'generated_at' => gmdate('c'),
    'range'        => $range,
    'sensors'      => $sensorsOut,
    'series'       => $series,
    'count'        => count($rows),
], JSON_UNESCAPED_SLASHES);
