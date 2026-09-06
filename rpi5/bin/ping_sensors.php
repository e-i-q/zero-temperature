#!/usr/bin/env php
<?php
/**
 * ping_sensors.php — Hive-side liveness check for every registered Pi Zero.
 *
 * Run every minute by cron (see setup/setup_sensor_pinger.sh), this is what
 * actually decides a sensor's ONLINE/OFFLINE badge on the dashboard — not
 * the recency of its last DHT22 reading (see api/readings.php's `online`
 * field, PING_STALE_SECONDS). That split matters: a Pi Zero whose DHT22
 * has come loose keeps answering here even while it reports zero
 * successful readings, so it shows ONLINE + FAULTY DHT22 instead of a
 * misleading OFFLINE.
 *
 * For each registered sensor, opens a short TCP connection to port 80 on
 * its `ip_address` (falling back to `<name>.local`, the same convention
 * api/sync_trigger.php and api/deploy_trigger.php use) — reachability
 * alone is enough, no HTTP request is actually sent over it. A successful
 * connection stamps `sensors.last_ping_at = now()`; a failure leaves it
 * untouched, so it's api/readings.php's staleness check that actually
 * flips the badge to OFFLINE once enough pings in a row have failed.
 *
 * This is deliberately not run from web/ — it's cron-only, invoked
 * directly from the git checkout (see setup_sensor_pinger.sh), not synced
 * into the nginx web root by deploy_web.sh, so it's never web-reachable.
 *
 * Connects as the `sensor_pinger` role — read/write on `sensors` only, not
 * `readings` — kept separate from both `web_reader` (deliberately
 * read-only there) and `sensor_writer` (which can also write fabricated
 * temperature readings); see ../../db/database/sensors/meta.md. Needs its
 * own ~/.pgpass entry for whichever user runs this on cron — see
 * setup/setup_sensor_pinger.sh.
 *
 * Usage: php ping_sensors.php   (silent on success; errors go to stderr)
 */

declare(strict_types=1);

const PG_HOST = '127.0.0.1'; // the Hive database runs on this same Pi 5
const PG_PORT = 5432;
const PG_DBNAME = 'sensors';
const PG_USER = 'sensor_pinger';

// Short enough that one unreachable/slow sensor doesn't stall the whole
// once-a-minute run for the rest of the fleet.
const CONNECT_TIMEOUT_SECONDS = 3;

try {
    $pdo = new PDO(
        sprintf('pgsql:host=%s;port=%d;dbname=%s', PG_HOST, PG_PORT, PG_DBNAME),
        PG_USER,
        null,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException $e) {
    fwrite(STDERR, "Could not connect to the Hive database: {$e->getMessage()}\n");
    exit(1);
}

$sensors = $pdo->query('SELECT name, ip_address FROM sensors')->fetchAll(PDO::FETCH_ASSOC);
$markSeen = $pdo->prepare('UPDATE sensors SET last_ping_at = now() WHERE name = :name');

foreach ($sensors as $row) {
    $name = (string) $row['name'];
    // Prefer the address dht22_logger.py keeps current on every successful
    // write (see remote_db.py's register_sensor); fall back to mDNS for a
    // sensor that's never gone through that code path yet.
    $host = ($row['ip_address'] !== null && $row['ip_address'] !== '') ? $row['ip_address'] : "{$name}.local";

    $errno = 0;
    $errstr = '';
    $conn = @fsockopen($host, 80, $errno, $errstr, CONNECT_TIMEOUT_SECONDS);
    if ($conn === false) {
        continue; // unreachable this tick — leave last_ping_at as-is
    }
    fclose($conn);
    $markSeen->execute(['name' => $name]);
}
