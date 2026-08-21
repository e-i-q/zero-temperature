<?php
/**
 * daily.php — JSON endpoint for the Hive dashboard's long-term chart:
 * per-sensor daily mean/min/max temperature over the last MONTHS_BACK
 * months, aggregated in PostgreSQL rather than shipping raw rows for a
 * year+ of history to the browser.
 */

declare(strict_types=1);

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

const MONTHS_BACK = 12;

$pdo = db();

try {
    $sensors = $pdo->query('SELECT id, name, description FROM sensors ORDER BY name')->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Could not read sensor registry: ' . $e->getMessage());
}

try {
    $stmt = $pdo->prepare(
        "SELECT sensor_id,
                date_trunc('day', recorded_at) AS day,
                avg(temperature_c) AS temp_avg,
                min(temperature_c) AS temp_min,
                max(temperature_c) AS temp_max
         FROM readings
         WHERE recorded_at >= now() - make_interval(months => :months)
         GROUP BY sensor_id, day
         ORDER BY day ASC"
    );
    $stmt->bindValue(':months', MONTHS_BACK, PDO::PARAM_INT);
    $stmt->execute();
    $rows = $stmt->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Query failed: ' . $e->getMessage());
}

$series = [];
foreach ($sensors as $s) {
    $series[(int) $s['id']] = [];
}
foreach ($rows as $row) {
    $sid = (int) $row['sensor_id'];
    if (!array_key_exists($sid, $series)) {
        continue;
    }
    $series[$sid][] = [
        'day'      => substr((string) $row['day'], 0, 10), // YYYY-MM-DD
        'temp_avg' => round((float) $row['temp_avg'], 2),
        'temp_min' => round((float) $row['temp_min'], 2),
        'temp_max' => round((float) $row['temp_max'], 2),
    ];
}

echo json_encode([
    'generated_at' => gmdate('c'),
    'months'       => MONTHS_BACK,
    'sensors'      => array_map(fn($s) => ['id' => (int) $s['id'], 'name' => $s['name']], $sensors),
    'series'       => $series,
], JSON_UNESCAPED_SLASHES);
