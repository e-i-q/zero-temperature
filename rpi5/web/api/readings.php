<?php
/**
 * readings.php — JSON endpoint for the Hive dashboard: every registered
 * sensor's readings within the requested window, queried live from the
 * central PostgreSQL database (no caching — this is the whole point of
 * centralizing the data).
 *
 * Query params (all optional):
 *   ?range=24h   A <number><unit> token (unit one of h/d/w/m — hours, days,
 *                weeks, months) or "all". Default 24h. Historically a fixed
 *                enum (12h/24h/2d/5d/1m); now the Settings tab lets a
 *                logged-in profile define its own token set
 *                (web/api/settings.php), so this parses the general shape
 *                instead of matching against a hardcoded list — see
 *                rangeModifier() below.
 */

declare(strict_types=1);

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

// -- Configuration ----------------------------------------------------------
const DEFAULT_RANGE = '24h';

// Turns a "<number><unit>" token into a PHP relative-date modifier
// (DateTime::modify), not SQL — the cutoff is computed here and bound as a
// plain timestamp, rather than asking PostgreSQL to parse an interval
// string. That sidesteps a real PDO_PGSQL gotcha: a `::type` cast placed
// directly after a bound `:placeholder` (e.g. `:window::interval`) confuses
// PDO's own placeholder parser and throws a "syntax error" PDOException
// before the query ever reaches PostgreSQL — see
// https://bugs.php.net/bug.php?id=80863 and friends.
// Returns null for anything that isn't a valid token (including "all",
// which the caller handles separately since it has no fixed modifier).
function rangeModifier(string $range): ?string {
    if (!preg_match('/^([1-9]\d{0,2})(h|d|w|m)$/', $range, $m)) {
        return null;
    }
    $units = ['h' => 'hours', 'd' => 'days', 'w' => 'weeks', 'm' => 'months'];
    return '-' . $m[1] . ' ' . $units[$m[2]];
}

// ONLINE/OFFLINE is decided by rpi5/bin/ping_sensors.php's TCP reachability
// check (cron, every minute — see sensors.last_ping_at), not by reading
// recency: a sensor with a loose DHT22 keeps answering pings even while it
// reports nothing, and should show ONLINE + FAULTY DHT22, not a misleading
// OFFLINE. This tolerates one missed/slow ping tick before flagging.
const PING_STALE_SECONDS = 90;

// Safety cap on rows returned for the "all" range on a long-running install
// — the dashboard downsamples nothing server-side, so this bounds payload
// size rather than the (unbounded) time window itself.
const MAX_ROWS = 20000;

// -- Parse + validate query params ------------------------------------------
$range = (string) ($_GET['range'] ?? DEFAULT_RANGE);
$modifier = $range === 'all' ? null : rangeModifier($range);
if ($range !== 'all' && $modifier === null) {
    $range = DEFAULT_RANGE;
    $modifier = rangeModifier(DEFAULT_RANGE);
}

$pdo = db();

// -- Sensor registry — always return every sensor, even ones with zero
// readings in this window, so the dashboard can still render an offline
// tile for them instead of silently dropping them. --------------------------
try {
    $sensors = $pdo->query('SELECT id, name, description, ip_address, status, uptime_seconds, commit_hash, commit_summary, commit_date, last_ping_at, dht22_fault_at FROM sensors ORDER BY name')->fetchAll();
} catch (PDOException $e) {
    fail(500, 'Could not read sensor registry: ' . $e->getMessage());
}

// -- Readings -----------------------------------------------------------------
$sql = 'SELECT sensor_id, recorded_at, temperature_c, humidity_pct, sample_count, attempt_count, max_attempts FROM readings';
if ($range !== 'all') {
    $sql .= ' WHERE recorded_at >= :since';
}
$sql .= ' ORDER BY recorded_at ASC LIMIT :limit';

try {
    $stmt = $pdo->prepare($sql);
    if ($range !== 'all') {
        // recorded_at is UTC wall-clock (no tz) — compute the cutoff in UTC
        // too, so this doesn't drift with the web server's local time zone.
        $since = new DateTimeImmutable('now', new DateTimeZone('UTC'));
        $since = $since->modify($modifier);
        $stmt->bindValue(':since', $since->format('Y-m-d H:i:s'), PDO::PARAM_STR);
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
        'recorded_at'   => toIsoUtc($row['recorded_at']),
        'temperature_c' => round((float) $row['temperature_c'], 2),
        'humidity_pct'  => round((float) $row['humidity_pct'], 2),
        'sample_count'  => (int) $row['sample_count'],
        // Total attempts this run made and its configured ceiling — null
        // together for rows predating this tracking (see readings.md in
        // the `db` project). script.js's formatSamples() falls back to
        // plain sample_count when either is null.
        'attempt_count' => $row['attempt_count'] !== null ? (int) $row['attempt_count'] : null,
        'max_attempts'  => $row['max_attempts'] !== null ? (int) $row['max_attempts'] : null,
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
    $lastPingTs = $s['last_ping_at'] !== null ? strtotime($s['last_ping_at']) : false;
    $online = $lastPingTs !== false && ($nowTs - $lastPingTs) <= PING_STALE_SECONDS;

    $temps = array_column($pts, 'temperature_c');
    $hums  = array_column($pts, 'humidity_pct');

    $sensorsOut[] = [
        'id'          => $sid,
        'name'        => $s['name'],
        'description' => $s['description'],
        'ip_address'  => $s['ip_address'],
        // Live power state from ups_ina219.py's remote_db.update_status()
        // — "OK" / "CHARGING <pct>%" / "BATTERY <pct>%", or null for a
        // sensor with no UPS HAT (or one that's never run that script).
        // script.js treats null the same as "OK" while the sensor is online.
        'status'      => $s['status'],
        // Seconds since this sensor's Pi last booted, from
        // uptime_reporter.py's remote_db.update_uptime() — see
        // ../../../../db/database/sensors/tables/sensors.md. Null if that
        // reporter has never run here. Shown on the Settings tab's Sensors
        // section (script.js's formatUptime()), not per-tile — unlike
        // `status`, it isn't relevant to the Overview tab's at-a-glance view.
        'uptime_seconds' => $s['uptime_seconds'] !== null ? (int) $s['uptime_seconds'] : null,
        // Currently-deployed git commit on this sensor Pi, from
        // report_version.py's remote_db.update_version() — see
        // ../../../../db/database/sensors/tables/sensors.md. Null (all
        // three together) if that reporter has never run here. Shown on
        // the Settings tab's Sensors section (script.js), same place as
        // uptime_seconds above.
        'commit_hash'    => $s['commit_hash'],
        'commit_summary' => $s['commit_summary'],
        'commit_date'    => $s['commit_date'] !== null ? toIsoTz($s['commit_date']) : null,
        // Ping-derived reachability (rpi5/bin/ping_sensors.php), not reading
        // recency — see PING_STALE_SECONDS above and sensors.last_ping_at in
        // ../../../../db/database/sensors/tables/sensors.md. Independent of
        // `status`/`dht22_fault` below: all three can be true/set at once.
        'online'         => $online,
        'last_ping_at'   => $s['last_ping_at'] !== null ? toIsoTz($s['last_ping_at']) : null,
        // Set by dht22_logger.py's remote_db.update_dht22_fault() the first
        // time a run gets zero successful DHT22 reads; cleared on the next
        // run with at least one. Drives the "FAULTY DHT22" badge — see
        // ../../../../db/database/sensors/tables/sensors.md.
        'dht22_fault'       => $s['dht22_fault_at'] !== null,
        'dht22_fault_since' => $s['dht22_fault_at'] !== null ? toIsoTz($s['dht22_fault_at']) : null,
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
