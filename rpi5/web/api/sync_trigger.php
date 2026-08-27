<?php
/**
 * sync_trigger.php — Hive-side relay for the Settings tab's "Sync Now"
 * buttons: looks up a sensor's address and calls that Pi Zero's own
 * web/sync.php to run its backlog sync, then relays the result back.
 *
 * Why a relay instead of doing the sync here: only the Pi Zero itself has
 * both its local unsynced readings and the outbound path to this database.
 * "Sync now" from the Hive can only ever mean "ask that Pi Zero to run its
 * own sync_backlog.py" — this file is just the messenger.
 *
 * Gated behind the same Settings-tab login as settings.php ($_SESSION
 * ['password_id']) — that authenticates the BROWSER to this server. The
 * X-Sync-Token sent on to the Pi Zero below is a separate secret that
 * authenticates this SERVER to the Pi Zero; see rpi-zero/web/sync.php and
 * setup_sync_trigger.sh on both sides.
 *
 * Request:  POST {"sensor": "<name>"} (X-Requested-With: fetch, same speed
 *           bump as settings.php).
 * Response: whatever JSON web/sync.php returned, i.e.
 *           {"ok": true, "output": "..."} or {"ok": false, "error": "..."}.
 */

declare(strict_types=1);

const SYNC_TOKEN_FILE = '/etc/dht22-sync/token';
// A first-time full-history backlog sync on the Pi Zero can take a while
// (see sync_backlog.py's docstring) — this is a one-off manual action, not
// something on a tight polling loop, so a generous timeout is fine.
const REQUEST_TIMEOUT_SECONDS = 60;

// Just reads the session settings.php's login already established — no
// need to repeat its session_set_cookie_params() call, since that only
// matters when a NEW cookie is about to be issued.
session_start();

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'fetch') {
    fail(400, 'Missing required header.');
}
if (empty($_SESSION['password_id'])) {
    fail(401, 'Log in on the Settings tab first.');
}

$input = json_decode((string) file_get_contents('php://input'), true);
$sensorName = is_array($input) ? (string) ($input['sensor'] ?? '') : '';
if ($sensorName === '') {
    fail(400, 'sensor is required.');
}

$pdo = db();
$stmt = $pdo->prepare('SELECT ip_address FROM sensors WHERE name = :name');
$stmt->execute(['name' => $sensorName]);
$row = $stmt->fetch();
if (!$row) {
    fail(404, "Unknown sensor: {$sensorName}");
}

// Prefer the address dht22_logger.py keeps current on every successful
// write (see remote_db.py's register_sensor); fall back to mDNS for a
// sensor that's never gone through that code path yet (e.g. it's only ever
// reached this database via a version of the code predating ip_address).
$host = ($row['ip_address'] !== null && $row['ip_address'] !== '')
    ? $row['ip_address']
    : $sensorName . '.local';

if (!is_file(SYNC_TOKEN_FILE)) {
    fail(500, 'Sync trigger is not configured on the Hive — run rpi5/setup/setup_sync_trigger.sh.');
}
$token = trim((string) file_get_contents(SYNC_TOKEN_FILE));

// file_get_contents + stream context instead of curl, same as
// api/forecast.php (setup_nginx_php.sh doesn't install php-curl).
$context = stream_context_create([
    'http' => [
        'method'        => 'POST',
        'header'        => "X-Sync-Token: {$token}\r\n",
        'timeout'       => REQUEST_TIMEOUT_SECONDS,
        'ignore_errors' => true, // so a non-2xx response body is still readable, not just `false`
    ],
]);
$body = @file_get_contents("http://{$host}/sync.php", false, $context);

if ($body === false) {
    fail(502, "Could not reach {$sensorName} at {$host}.");
}

$decoded = json_decode($body, true);
if (!is_array($decoded)) {
    fail(502, "Unexpected response from {$sensorName} (" . substr($body, 0, 300) . ')');
}

echo json_encode($decoded);
