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
    // Temperature calibration offset per sensor (Settings tab, see
    // readings.php's docstring) — applied to the daily aggregates below so
    // the long-term chart agrees with the rest of the dashboard.
    $sensors = $pdo->query(
        tableExists($pdo, 'sensor_offsets')
            ? 'SELECT s.id, s.name, s.description, o.temp_offset_c
               FROM sensors s
               LEFT JOIN sensor_offsets o ON o.sensor_id = s.id
               ORDER BY s.name'
            : 'SELECT id, name, description, NULL AS temp_offset_c FROM sensors ORDER BY name'
    )->fetchAll();
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
         WHERE recorded_at >= :since
         GROUP BY sensor_id, day
         ORDER BY day ASC"
    );
    // Computed in PHP (UTC, matching recorded_at's storage convention) and
    // bound as a plain timestamp — see readings.php's rangeModifier()
    // comment for why this avoids asking PostgreSQL to parse an interval.
    $since = new DateTimeImmutable('now', new DateTimeZone('UTC'));
    $since = $since->modify('-' . MONTHS_BACK . ' months');
    $stmt->bindValue(':since', $since->format('Y-m-d H:i:s'), PDO::PARAM_STR);
    $stmt->execute();
    $rows = $stmt->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Query failed: ' . $e->getMessage());
}

$series = [];
$tempOffsets = [];
foreach ($sensors as $s) {
    $series[(int) $s['id']] = [];
    $tempOffsets[(int) $s['id']] = (float) ($s['temp_offset_c'] ?? 0);
}
foreach ($rows as $row) {
    $sid = (int) $row['sensor_id'];
    if (!array_key_exists($sid, $series)) {
        continue;
    }
    $series[$sid][] = [
        'day'      => substr((string) $row['day'], 0, 10), // YYYY-MM-DD
        'temp_avg' => round((float) $row['temp_avg'] + $tempOffsets[$sid], 2),
        'temp_min' => round((float) $row['temp_min'] + $tempOffsets[$sid], 2),
        'temp_max' => round((float) $row['temp_max'] + $tempOffsets[$sid], 2),
    ];
}

echo json_encode([
    'generated_at' => gmdate('c'),
    'months'       => MONTHS_BACK,
    'sensors'      => array_map(fn($s) => ['id' => (int) $s['id'], 'name' => $s['name']], $sensors),
    'series'       => $series,
], JSON_UNESCAPED_SLASHES);
